#requires -Version 7.0

<#
.SYNOPSIS
    Wrapper-owned Teams notification module for the reviewer agent (opt-in,
    -EnableTeamsNotifications).

.DESCRIPTION
    This file is dot-sourced only by Start-ReviewerAgent.ps1, AFTER
    Set-ReviewerVote.ps1 (it reuses that file's generic MCP JSON-RPC framing
    helpers: Test-AgencyMcpGuid, Test-AgencyMcpStrictInt,
    Get-AgencyMcpRequiredProperty, Set-AgencyMcpProcessArguments,
    Stop-AgencyMcpProcessTree). It never runs unless the operator explicitly
    passes -EnableTeamsNotifications; the checked-in
    config.teamsNotifications section alone can never enable a write.

    SECURITY MODEL:
      - Every Teams write (channel post, chat create, chat post) is issued by
        this trusted wrapper directly over `agency mcp workiq` JSON-RPC/stdio,
        exactly like the existing Agency ADO MCP vote client. The reviewing
        Copilot model is NEVER granted a workiq/Teams/chat tool - it is not
        registered in .mcp.json for the model's session, and this module also
        adds explicit workiq(*) deny-tool entries (Start-ReviewerAgent.ps1)
        as defense in depth.
      - Only a fixed, code-built HTML template is ever sent. Every dynamic
        value (repo, PR id/link, commit, findings, recommendation, vote) is
        passed through ConvertTo-ReviewerHtmlEncoded ([System.Net.WebUtility]
        ::HtmlEncode) - model output never controls markup, and every field
        plus the total message is length-bounded.
      - The PR link is derived from validated config org/project/repo plus
        the wrapper's own numeric candidate.prId - never a model-supplied URL.
      - Outbox state (notifications.json) lives under the same wrapper-owned
        -StateDir as votes.json/reviewed.json: pending is persisted BEFORE
        any external write, and before (re)posting the drain loop fetches a
        bounded page of recent destination messages and checks for the fixed
        deterministic event-id marker to avoid duplicate delivery.
      - Notification failures are recorded (attempts/backoff/lastError) and
        surfaced in logs, but a notification failure can NEVER change a vote
        outcome, fail an otherwise successful review, or stop the main loop.
        Every caller in Start-ReviewerAgent.ps1 wraps drain calls in try/catch
        that only logs.
      - A Teams Workflows (Power Automate) webhook is an OPTIONAL channel-only
        fallback. Its URL is read ONLY at runtime from the environment
        variable NAMED by config (never checked in, never logged/persisted),
        must be https, and must resolve to a *.logic.azure.com host. Legacy
        Office 365 Connector webhooks (webhook.office.com / outlook office
        connectors) are retired and explicitly unsupported here.
#>

Set-StrictMode -Version Latest

$script:ReviewerTeamsSupportedEvents = @("startup", "shutdown", "reviewCompleted", "reviewFailed", "candidateStarved")
# Direct-author messages are PR-specific; there is no "author" for
# process-lifecycle events, so startup/shutdown are never valid there.
$script:ReviewerTeamsAuthorOnlyEvents = @("reviewCompleted", "reviewFailed", "candidateStarved")
$script:ReviewerTeamsMaxFieldLength = 500
# Fixed literal, never built from dynamic input: every outgoing message opens
# with this so a recipient can tell at a glance that the signed-in user did
# not type it by hand.
$script:ReviewerTeamsAutomatedBanner = "<p><b>[Automated message]</b> Sent by the API Hub reviewer agent on behalf of the signed-in user. Do not reply.</p>"
$script:ReviewerTeamsMaxPrLinkLength = 300
$script:ReviewerTeamsMaxHtmlLength = 8000
$script:ReviewerTeamsMaxDrainPerCycle = 20
$script:ReviewerTeamsHtmlEncoder = [System.Net.WebUtility]
# Outbox schema version 2 adds a per-entry random delivery marker (dedupe is
# keyed on THIS, never the predictable deterministic event id) and, for
# directAuthor entries only, the exact validated ADO createdBy.uniqueName
# captured at enqueue time. Entries written by schema version 1 (or missing
# these fields entirely) are legacy and are never silently upgraded/routed -
# see the migration handling in Invoke-ReviewerTeamsNotificationDrain.
$script:ReviewerTeamsOutboxSchemaVersion = 2
$script:ReviewerTeamsMarkerHexLength = 48
$script:ReviewerTeamsMarkerPattern = "^[0-9a-f]{$($script:ReviewerTeamsMarkerHexLength)}`$"
# Schema-v1 entries never had a random deliveryMarker at all: their outgoing
# HTML embedded the deterministic eventId itself (see Get-ReviewerTeamsEventId
# - "<NAMESPACE>-RVW-" + 16 lowercase hex chars) as the dedupe marker, because
# the random per-entry marker did not exist yet. This bounded pattern is used
# ONLY to recognize/validate that legacy value for a one-time migration
# dedupe check - never to mint or accept a new marker in this shape.
#
# The namespace is derived from config.stateNamespace so each consuming repo
# gets its own dedupe namespace rather than sharing a hardcoded one. The
# default below only applies if this helper is dot-sourced without a wrapper.
$script:ReviewerTeamsEventIdNamespace = 'DEVPILOT'
$script:ReviewerTeamsLegacyEventIdPattern = "^$($script:ReviewerTeamsEventIdNamespace)-RVW-[0-9a-f]{16}`$"

function Set-ReviewerTeamsEventIdNamespace {
    <#
        Called by the wrapper once config has loaded. Uppercased and stripped
        to A-Z0-9 so the resulting id stays matchable by the bounded patterns
        above. A consumer whose stateNamespace is "ExampleRepo" therefore keeps
        producing "EXAMPLEREPO-RVW-..." exactly as before, so no already-sent
        message stops being recognized when this moves between repositories.
    #>
    param([Parameter(Mandatory)][string]$Namespace)
    $clean = ($Namespace -replace '[^A-Za-z0-9]', '').ToUpperInvariant()
    if ([string]::IsNullOrWhiteSpace($clean)) { throw "stateNamespace '$Namespace' contains no alphanumeric characters usable as a Teams event-id namespace." }
    $script:ReviewerTeamsEventIdNamespace = $clean
    $script:ReviewerTeamsLegacyEventIdPattern = "^$clean-RVW-[0-9a-f]{16}`$"
}
# Same bounded, email-shaped validation Set-ReviewerVote.ps1 applies to the
# trusted ADO createdBy.uniqueName before it is ever accepted here.
$script:ReviewerTeamsAuthorUniqueNamePattern = '^[^@\s]+@[^@\s]+\.[^@\s]+$'
$script:ReviewerTeamsMaxAuthorUniqueNameLength = 320

function New-ReviewerTeamsDeliveryMarker {
    <#
        Cryptographically random per-entry marker, generated and persisted
        BEFORE any external write. This is the ONLY value dedupe scanning
        trusts - unlike the deterministic event id (which is derivable by
        anyone who knows the PR/commit/outcome and could be pre-posted by a
        PR author to suppress delivery), this marker cannot be guessed.
    #>
    $bytes = [byte[]]::new(24)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    return -join ($bytes | ForEach-Object { $_.ToString("x2") })
}

function Test-ReviewerTeamsDeliveryMarker {
    param([AllowNull()][string]$Marker)
    return ($Marker -is [string]) -and ($Marker -cmatch $script:ReviewerTeamsMarkerPattern)
}

function Test-ReviewerTeamsAuthorUniqueName {
    param([AllowNull()][string]$AuthorUniqueName)
    if ([string]::IsNullOrWhiteSpace($AuthorUniqueName)) { return $false }
    if ($AuthorUniqueName.Length -gt $script:ReviewerTeamsMaxAuthorUniqueNameLength) { return $false }
    return $AuthorUniqueName -cmatch $script:ReviewerTeamsAuthorUniqueNamePattern
}

function ConvertTo-ReviewerHtmlEncoded {
    <#
        Bounds the RAW value length first (never the already-encoded string -
        encoding can only expand length, e.g. "&" -> "&amp;"), then HTML
        encodes with a real encoder. This is the ONLY way dynamic values may
        ever enter a notification template.
    #>
    param([AllowNull()][string]$Value, [int]$MaxLength = $script:ReviewerTeamsMaxFieldLength)
    if ([string]::IsNullOrEmpty($Value)) { return "" }
    $trimmed = $Value
    $truncated = $false
    if ($trimmed.Length -gt $MaxLength) {
        $trimmed = $trimmed.Substring(0, $MaxLength)
        $truncated = $true
    }
    $encoded = $script:ReviewerTeamsHtmlEncoder::HtmlEncode($trimmed)
    if ($truncated) { $encoded += "&#8230;" }
    return $encoded
}

function Get-ReviewerTeamsEventId {
    <#
        Deterministic per (destination, event, PR, source commit, outcome)
        marker. Re-enqueuing the identical logical event (e.g. the drain loop
        running again) produces the SAME id, which is how dedupe / "already
        sent" detection works both in the local outbox and by scanning
        recent destination messages.
    #>
    param(
        [Parameter(Mandatory)][string]$DestinationKey,
        [Parameter(Mandatory)][ValidateSet("startup", "shutdown", "reviewCompleted", "reviewFailed", "candidateStarved")][string]$Event,
        [AllowNull()][string]$PrId,
        [AllowNull()][string]$SourceCommit,
        [AllowNull()][string]$VoteOutcome
    )
    $basis = "$DestinationKey|$Event|$PrId|$SourceCommit|$VoteOutcome"
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($basis))
    }
    finally { $sha256.Dispose() }
    $hex = -join ($hash[0..7] | ForEach-Object { $_.ToString("x2") })
    return "$($script:ReviewerTeamsEventIdNamespace)-RVW-$hex"
}

function Get-ReviewerCanonicalPullRequestLink {
    <#
        Built ONLY from wrapper-validated config (organization/project/
        repository name, all already regex-validated at config load) plus the
        wrapper's own numeric candidate PR id - never a model-supplied URL.
    #>
    param(
        [Parameter(Mandatory)][string]$Organization,
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][string]$RepositoryName,
        [Parameter(Mandatory)][int]$PrId
    )
    if ($PrId -le 0) { throw "Refusing to build a PR link for a non-positive PR id." }
    $encodedProject = [Uri]::EscapeDataString($Project)
    return "https://dev.azure.com/$Organization/$encodedProject/_git/$RepositoryName/pullrequest/$PrId"
}

# The exact scheme/host Get-ReviewerCanonicalPullRequestLink above builds.
# A fork targeting a different Azure DevOps host must update BOTH.
$script:ReviewerTeamsPrLinkScheme = "https"
$script:ReviewerTeamsPrLinkHost = "dev.azure.com"

function Test-ReviewerTeamsCanonicalPrLink {
    <#
        HtmlEncode makes a value safe as TEXT, but NOT safe as an href
        TARGET: it neither rejects a dangerous scheme (javascript:, data:,
        vbscript:) nor an off-domain https:// destination. Today $PrLink is
        always wrapper-built by Get-ReviewerCanonicalPullRequestLink from
        validated config plus a numeric PR id, so this can never fail - it
        exists so the anchor stays safe BY CONSTRUCTION if that value ever
        becomes data-derived, instead of leaving Teams' own sanitizer as the
        only barrier. Callers render a non-canonical value as plain text.
    #>
    param([AllowNull()][string]$PrLink, [Parameter(Mandatory)][int]$PrId)
    if ([string]::IsNullOrWhiteSpace($PrLink)) { return $false }
    if ($PrLink.Length -gt $script:ReviewerTeamsMaxPrLinkLength) { return $false }
    if ($PrId -le 0) { return $false }
    $uri = $null
    if (-not [Uri]::TryCreate($PrLink, [UriKind]::Absolute, [ref]$uri)) { return $false }
    if ($uri.Scheme -cne $script:ReviewerTeamsPrLinkScheme) { return $false }
    if ($uri.Host -cne $script:ReviewerTeamsPrLinkHost) { return $false }
    if ($uri.UserInfo) { return $false }
    # The link must actually address THIS pull request. $PrId is a bound
    # [int], so it can carry no regex metacharacters.
    return $uri.AbsolutePath -cmatch "/_git/[^/]+/pullrequest/$PrId`$"
}

function New-ReviewerTeamsNotificationHtml {
    <#
        The ONLY function that builds outgoing message HTML. Every dynamic
        field passes through ConvertTo-ReviewerHtmlEncoded; the surrounding
        markup is a fixed literal template. The one href in this template is
        additionally scheme/host/PR-id validated (see
        Test-ReviewerTeamsCanonicalPrLink) and degrades to plain text. Includes an HTML-comment
        DELIVERY MARKER (a per-entry cryptographically random value, NOT the
        deterministic event id) used for later dedupe scanning - the
        deterministic id is predictable from PR/commit/outcome and could be
        pre-posted by the PR author to suppress delivery, so it is never used
        as the dedupe token itself.
    #>
    param(
        [Parameter(Mandatory)][string]$DeliveryMarker,
        [Parameter(Mandatory)][ValidateSet("startup", "shutdown", "reviewCompleted", "reviewFailed", "candidateStarved")][string]$Event,
        [Parameter(Mandatory)][string]$Repository,
        [AllowNull()][Nullable[int]]$PrId,
        [AllowNull()][string]$PrLink,
        [AllowNull()][string]$Commit,
        [AllowNull()][string]$Findings,
        [AllowNull()][string]$Recommendation,
        [AllowNull()][string]$RequestedVote,
        [AllowNull()][string]$VoteOutcome
    )
    $rows = New-Object System.Collections.Generic.List[string]
    # Fixed literal banner, first line of every message. These are posted by
    # the reviewer agent AS the signed-in user, so without this a recipient
    # would reasonably assume a human typed and sent it.
    $rows.Add($script:ReviewerTeamsAutomatedBanner)
    $rows.Add("<p><b>Event:</b> $(ConvertTo-ReviewerHtmlEncoded -Value $Event -MaxLength 64)</p>")
    $rows.Add("<p><b>Repository:</b> $(ConvertTo-ReviewerHtmlEncoded -Value $Repository -MaxLength 200)</p>")
    if ($PrId) {
        $encodedLink = ConvertTo-ReviewerHtmlEncoded -Value $PrLink -MaxLength $script:ReviewerTeamsMaxPrLinkLength
        if (-not $encodedLink) {
            $rows.Add("<p><b>Pull Request:</b> #$([int]$PrId)</p>")
        }
        elseif (Test-ReviewerTeamsCanonicalPrLink -PrLink $PrLink -PrId ([int]$PrId)) {
            $rows.Add("<p><b>Pull Request:</b> #$([int]$PrId) - <a href=`"$encodedLink`">$encodedLink</a></p>")
        }
        else {
            # Fail safe: a value that is not a canonical PR URL is shown as
            # inert text, never promoted to a clickable target.
            $rows.Add("<p><b>Pull Request:</b> #$([int]$PrId) - $encodedLink (not rendered as a link: not a canonical $($script:ReviewerTeamsPrLinkHost) pull-request URL)</p>")
        }
    }
    if ($Commit) {
        $rows.Add("<p><b>Commit:</b> $(ConvertTo-ReviewerHtmlEncoded -Value $Commit -MaxLength 64)</p>")
    }
    if ($Findings) {
        $rows.Add("<p><b>Findings:</b> $(ConvertTo-ReviewerHtmlEncoded -Value $Findings -MaxLength 800)</p>")
    }
    if ($Recommendation) {
        $rows.Add("<p><b>Recommendation:</b> $(ConvertTo-ReviewerHtmlEncoded -Value $Recommendation -MaxLength 200)</p>")
    }
    if ($RequestedVote) {
        $rows.Add("<p><b>Requested vote:</b> $(ConvertTo-ReviewerHtmlEncoded -Value $RequestedVote -MaxLength 32)</p>")
    }
    if ($VoteOutcome) {
        $rows.Add("<p><b>Vote outcome:</b> $(ConvertTo-ReviewerHtmlEncoded -Value $VoteOutcome -MaxLength 32)</p>")
    }
    $body = ($rows -join "")
    $html = "<div>$body<!-- $DeliveryMarker --></div>"
    if ($html.Length -gt $script:ReviewerTeamsMaxHtmlLength) {
        # The marker MUST survive even under the hard cap (dedupe depends on
        # it), so trim the body, never the trailing marker comment.
        $overflow = $html.Length - $script:ReviewerTeamsMaxHtmlLength
        $trimmedBody = $body.Substring(0, [Math]::Max(0, $body.Length - $overflow - 40)) + "&#8230;"
        $html = "<div>$trimmedBody<!-- $DeliveryMarker --></div>"
    }
    return $html
}

# ---------------------------------------------------------------------------
# WorkIQ MCP transport (Agency-owned subprocess; never granted to Copilot)
# ---------------------------------------------------------------------------

$script:ReviewerWorkIqAllowedTools = @("fetch", "create_entity")
$script:ReviewerWorkIqAllowedPathPrefixes = @(
    "/me",
    "/users/",
    "/chats",
    "/teams/"
)

function Test-ReviewerWorkIqPathAllowed {
    param([Parameter(Mandatory)][string]$Path)
    if ($Path.Length -gt 512 -or $Path -match '[\r\n]') { return $false }
    foreach ($prefix in $script:ReviewerWorkIqAllowedPathPrefixes) {
        if ($Path -eq $prefix -or $Path.StartsWith($prefix, [StringComparison]::Ordinal)) { return $true }
    }
    return $false
}

function New-AgencyWorkIqMcpSession {
    param(
        [Parameter(Mandatory)][string]$AgencyPath,
        [Parameter(Mandatory)][string[]]$Subcommand,
        [ValidateRange(5, 120)][int]$TimeoutSeconds = 30
    )
    $processStartInfo = New-Object System.Diagnostics.ProcessStartInfo
    $processStartInfo.FileName = $AgencyPath
    Set-AgencyMcpProcessArguments -ProcessStartInfo $processStartInfo -ArgumentList @($Subcommand)
    $processStartInfo.UseShellExecute = $false
    $processStartInfo.RedirectStandardInput = $true
    $processStartInfo.RedirectStandardOutput = $true
    $processStartInfo.RedirectStandardError = $true
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    foreach ($propertyName in @("StandardInputEncoding", "StandardOutputEncoding", "StandardErrorEncoding")) {
        if ($processStartInfo.GetType().GetProperty($propertyName)) {
            $processStartInfo.$propertyName = $utf8
        }
    }
    $process = [System.Diagnostics.Process]::Start($processStartInfo)
    $session = @{
        Process        = $process
        NextId         = [long]0
        ReadTask       = $null
        ErrorDrainTask = $process.StandardError.ReadToEndAsync()
        TimeoutSeconds = $TimeoutSeconds
    }
    try {
        $initializeResult = Send-AgencyMcpRequest -Session $session -Method "initialize" -Params @{
            protocolVersion = $script:ReviewerAgencyMcpProtocolVersion
            capabilities    = @{}
            clientInfo      = @{
                name    = $script:ReviewerAgencyMcpClientName
                version = "1.0.0"
            }
        }
        if (-not $initializeResult.PSObject.Properties["protocolVersion"] -or
            [string]$initializeResult.protocolVersion -cne $script:ReviewerAgencyMcpProtocolVersion) {
            throw "Agency WorkIQ MCP negotiated an unsupported protocol version."
        }
        Send-AgencyMcpNotification -Session $session -Method "notifications/initialized"
        $toolsResult = Send-AgencyMcpRequest -Session $session -Method "tools/list" -Params @{}
        $toolsProperty = $toolsResult.PSObject.Properties["tools"]
        if (-not $toolsProperty) { throw "Agency WorkIQ MCP tools/list omitted tools." }
        $tools = @($toolsProperty.Value)
        foreach ($required in $script:ReviewerWorkIqAllowedTools) {
            $found = @($tools | Where-Object {
                $_ -is [System.Management.Automation.PSCustomObject] -and $_.PSObject.Properties["name"] -and [string]$_.name -ceq $required
            })
            if ($found.Count -lt 1) { throw "Agency WorkIQ MCP did not expose the required '$required' tool." }
        }
    }
    catch {
        Close-AgencyAdoMcpSession -Session $session -Abort
        throw
    }
    return $session
}

function Get-ReviewerWorkIqTargetUrl {
    <#
        Returns the single entity URL a WorkIQ call targets, per the tool's
        REAL argument contract: 'fetch' takes an entityUrls ARRAY, and
        'create_entity' takes a parentUrl string. (The wrapper previously
        passed a 'path' argument, which these tools simply do not accept.)
        Returning the URL from one place keeps the path allowlist below
        enforceable no matter which argument name a tool uses - if a future
        tool is added without a case here, it resolves to $null and the call
        is refused rather than silently escaping the allowlist.
    #>
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][hashtable]$Arguments)
    switch ($Name) {
        "fetch" {
            if (-not $Arguments.ContainsKey("entityUrls")) { return $null }
            $urls = @($Arguments["entityUrls"])
            # Exactly one entity per call keeps the allowlist check total and
            # the single-result response contract below unambiguous.
            if ($urls.Count -ne 1) { return $null }
            return [string]$urls[0]
        }
        "create_entity" {
            if (-not $Arguments.ContainsKey("parentUrl")) { return $null }
            return [string]$Arguments["parentUrl"]
        }
    }
    return $null
}

function Invoke-AgencyWorkIqTool {
    <#
        Exact allowed tool/URL enforcement: both the tool NAME (against a
        fixed short allowlist) and the target entity URL (against a fixed
        allowed-prefix list, query string stripped) are validated BEFORE the
        request is ever sent.

        WorkIQ answers with an EMPTY content array and puts the payload in
        structuredContent, in one of two shapes: 'fetch' returns a per-entity
        results[] array, while 'create_entity' returns a single
        {data, statusCode} envelope. Both are normalized here to one entry.
        A non-2xx entry is a failure even though the MCP call itself
        succeeded, so it is surfaced as one.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Session,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][hashtable]$Arguments,
        [Nullable[DateTime]]$DeadlineUtc
    )
    if ($script:ReviewerWorkIqAllowedTools -cnotcontains $Name) {
        throw "Refusing to call unlisted WorkIQ tool '$Name'."
    }
    $targetUrl = Get-ReviewerWorkIqTargetUrl -Name $Name -Arguments $Arguments
    if ([string]::IsNullOrWhiteSpace($targetUrl)) {
        throw "Refusing to call WorkIQ tool '$Name' without exactly one target entity URL."
    }
    # OData query options ($select/$top) are part of the URL, so compare only
    # the path portion against the allowed prefixes.
    $pathOnly = ($targetUrl -split '\?', 2)[0]
    if (-not (Test-ReviewerWorkIqPathAllowed -Path $pathOnly)) {
        throw "Refusing to call WorkIQ tool '$Name' with a disallowed path."
    }
    $toolResult = Send-AgencyMcpRequest -Session $Session -Method "tools/call" -Params @{
        name      = $Name
        arguments = $Arguments
    } -DeadlineUtc $DeadlineUtc
    if ($toolResult -isnot [System.Management.Automation.PSCustomObject]) {
        throw "Agency WorkIQ MCP tool returned an unexpected result shape."
    }
    $isErrorProperty = $toolResult.PSObject.Properties["isError"]
    if ($isErrorProperty -and [bool]$isErrorProperty.Value) {
        # Include the server's own message: discarding it previously made a
        # wrong-argument-shape bug indistinguishable from an auth failure.
        $detail = ""
        $errorContent = $toolResult.PSObject.Properties["content"]
        if ($errorContent) {
            $errorText = @(@($errorContent.Value) | Where-Object { $_.PSObject.Properties["text"] })[0]
            if ($errorText) {
                $detail = [string]$errorText.text
                if ($detail.Length -gt 300) { $detail = $detail.Substring(0, 300) + "..." }
            }
        }
        throw "Agency WorkIQ MCP tool '$Name' reported failure.$(if ($detail) { " Server said: $detail" })"
    }
    $structuredProperty = $toolResult.PSObject.Properties["structuredContent"]
    if (-not $structuredProperty -or $null -eq $structuredProperty.Value) {
        throw "Agency WorkIQ MCP tool '$Name' response omitted structuredContent."
    }
    $resultsProperty = $structuredProperty.Value.PSObject.Properties["results"]
    if ($resultsProperty) {
        # 'fetch' shape: one entry per requested entity URL. Exactly one is
        # requested, so exactly one must come back.
        $results = @($resultsProperty.Value)
        if ($results.Count -ne 1) {
            throw "Agency WorkIQ MCP tool '$Name' returned $($results.Count) results for a single-entity request."
        }
        $entry = $results[0]
    }
    else {
        # 'create_entity' shape: a single {data, statusCode} envelope.
        $entry = $structuredProperty.Value
    }
    if ($entry -isnot [System.Management.Automation.PSCustomObject]) {
        throw "Agency WorkIQ MCP tool '$Name' returned an unexpected result entry."
    }
    $statusProperty = $entry.PSObject.Properties["statusCode"]
    if (-not $statusProperty -or -not (Test-AgencyMcpStrictInt -Value $statusProperty.Value -Min 100 -Max 599)) {
        throw "Agency WorkIQ MCP tool '$Name' returned no valid statusCode."
    }
    $statusCode = [int]$statusProperty.Value
    if ($statusCode -lt 200 -or $statusCode -gt 299) {
        throw "Agency WorkIQ MCP tool '$Name' returned HTTP $statusCode for the requested entity."
    }
    $dataProperty = $entry.PSObject.Properties["data"]
    if (-not $dataProperty) {
        throw "Agency WorkIQ MCP tool '$Name' returned no data for the requested entity."
    }
    return $dataProperty.Value
}

function Send-ReviewerTeamsChannelMessage {
    param(
        [Parameter(Mandatory)][hashtable]$Session,
        [Parameter(Mandatory)][string]$TeamId,
        [Parameter(Mandatory)][string]$ChannelId,
        [Parameter(Mandatory)][string]$Html,
        [Nullable[DateTime]]$DeadlineUtc
    )
    $result = Invoke-AgencyWorkIqTool -Session $Session -Name "create_entity" -Arguments @{
        parentUrl = "/teams/$TeamId/channels/$ChannelId/messages"
        jsonBody  = @{ body = @{ contentType = "html"; content = $Html } }
    } -DeadlineUtc $DeadlineUtc
    return Get-AgencyMcpRequiredProperty -Object $result -Name "id"
}

function Resolve-ReviewerTeamsAuthorChatId {
    <#
        Resolves the exact author's one-on-one chat: fetch /me, fetch
        /users/{uniqueName}, then POST /chats with chatType=oneOnOne and two
        owner aadUserConversationMember entries. Microsoft Graph guarantees
        this returns the existing one-on-one chat if one already exists, so
        this is safe to call every time rather than caching indefinitely.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Session,
        [Parameter(Mandatory)][string]$AuthorUniqueName,
        [Nullable[DateTime]]$DeadlineUtc
    )
    $me = Invoke-AgencyWorkIqTool -Session $Session -Name "fetch" -Arguments @{
        entityUrls = @('/me?$select=id')
    } -DeadlineUtc $DeadlineUtc
    $selfId = Get-AgencyMcpRequiredProperty -Object $me -Name "id"
    $author = Invoke-AgencyWorkIqTool -Session $Session -Name "fetch" -Arguments @{
        entityUrls = @("/users/$([Uri]::EscapeDataString($AuthorUniqueName))?`$select=id")
    } -DeadlineUtc $DeadlineUtc
    $authorId = Get-AgencyMcpRequiredProperty -Object $author -Name "id"
    # Microsoft Graph's one-on-one chat creation (POST /chats,
    # chatType=oneOnOne) requires exactly two UNIQUE members; there is no
    # documented "chat with yourself" shape. Comparing the resolved ids here
    # - rather than letting the create_entity call below fail with an opaque
    # Graph error - gives both the live directAuthor path and
    # -TestTeamsNotifications -TeamsTestRecipient the same clear, actionable
    # message when the signed-in user and the recipient resolve to the same
    # person (e.g. an operator testing with their own UPN).
    $selfObjectId = [Guid]::Empty
    $authorObjectId = [Guid]::Empty
    if (-not [Guid]::TryParse([string]$selfId, [ref]$selfObjectId) -or
        -not [Guid]::TryParse([string]$authorId, [ref]$authorObjectId)) {
        throw "WorkIQ returned an invalid Microsoft Entra object id while resolving the signed-in user or Teams test recipient; refusing to create a chat."
    }
    if ($selfObjectId -eq $authorObjectId) {
        throw "Microsoft Graph does not support a one-on-one chat where the signed-in user and '$AuthorUniqueName' are the same person (POST /chats requires two unique members). Use a consenting teammate's UPN for direct testing, or test a configured Teams channel destination instead."
    }
    $chat = Invoke-AgencyWorkIqTool -Session $Session -Name "create_entity" -Arguments @{
        parentUrl = "/chats"
        jsonBody  = @{
            chatType = "oneOnOne"
            members  = @(
                @{
                    "@odata.type"     = "#microsoft.graph.aadUserConversationMember"
                    roles             = @("owner")
                    "user@odata.bind" = "https://graph.microsoft.com/v1.0/users('$selfId')"
                },
                @{
                    "@odata.type"     = "#microsoft.graph.aadUserConversationMember"
                    roles             = @("owner")
                    "user@odata.bind" = "https://graph.microsoft.com/v1.0/users('$authorId')"
                }
            )
        }
    } -DeadlineUtc $DeadlineUtc
    return Get-AgencyMcpRequiredProperty -Object $chat -Name "id"
}

function Send-ReviewerTeamsChatMessage {
    param(
        [Parameter(Mandatory)][hashtable]$Session,
        [Parameter(Mandatory)][string]$ChatId,
        [Parameter(Mandatory)][string]$Html,
        [Nullable[DateTime]]$DeadlineUtc
    )
    $result = Invoke-AgencyWorkIqTool -Session $Session -Name "create_entity" -Arguments @{
        parentUrl = "/chats/$ChatId/messages"
        jsonBody  = @{ body = @{ contentType = "html"; content = $Html } }
    } -DeadlineUtc $DeadlineUtc
    return Get-AgencyMcpRequiredProperty -Object $result -Name "id"
}

function Test-ReviewerTeamsRecentMessagesContainMarker {
    param(
        [Parameter(Mandatory)][hashtable]$Session,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Marker,
        [Nullable[DateTime]]$DeadlineUtc
    )
    try {
        # 'retrieve' is WorkIQ's semantic-search tool, not an entity read -
        # the dedupe scan needs the actual recent messages collection, so it
        # uses 'fetch' with the OData query carried in the URL.
        $result = Invoke-AgencyWorkIqTool -Session $Session -Name "fetch" -Arguments @{
            entityUrls = @("${Path}?`$top=20")
        } -DeadlineUtc $DeadlineUtc
    }
    catch {
        # A failed dedupe-check read must fail closed for THIS post attempt
        # (treat as "not yet confirmed sent", i.e. do not claim dedupe) but
        # must never throw out of the drain loop.
        return $false
    }
    $valueProperty = $result.PSObject.Properties["value"]
    if (-not $valueProperty) { return $false }
    foreach ($item in @($valueProperty.Value)) {
        $contentProp = $null
        if ($item.PSObject.Properties["body"] -and $item.body.PSObject.Properties["content"]) {
            $contentProp = [string]$item.body.content
        }
        if ($contentProp -and $contentProp.Contains($Marker)) { return $true }
    }
    return $false
}

# ---------------------------------------------------------------------------
# Teams Workflows (Power Automate) webhook fallback - channel only
# ---------------------------------------------------------------------------

function Send-ReviewerTeamsWorkflowsWebhook {
    <#
        Reads the webhook URL ONLY at call time from $env:<EnvironmentVariableName>.
        Never logs or persists the URL itself. Requires https and a host
        ending in '.logic.azure.com' (the genuine Power Automate / Teams
        Workflows trigger host). Legacy Office 365 Connector webhooks
        (webhook.office.com, outlook.office.com/webhook/...) are retired and
        are explicitly rejected, not merely undocumented.
    #>
    param(
        [Parameter(Mandatory)][string]$EnvironmentVariableName,
        [Parameter(Mandatory)][string]$Html,
        [ValidateRange(5, 120)][int]$TimeoutSeconds = 30
    )
    $url = [Environment]::GetEnvironmentVariable($EnvironmentVariableName)
    if ([string]::IsNullOrWhiteSpace($url)) {
        throw "Environment variable '$EnvironmentVariableName' is not set; the Teams Workflows webhook fallback is unavailable this cycle."
    }
    $uri = $null
    if (-not [Uri]::TryCreate($url, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -cne "https") {
        throw "The configured webhook environment variable does not hold a valid https URL."
    }
    if ($uri.Host -notmatch '(?i)^([a-z0-9-]+\.)*logic\.azure\.com$') {
        throw "The configured webhook host is not an allowed Teams Workflows (Power Automate) host; legacy Office 365 Connector webhooks are retired/unsupported."
    }
    $payload = @{ text = $Html } | ConvertTo-Json -Compress -Depth 5
    try {
        Invoke-RestMethod -Method Post -Uri $uri -Body $payload -ContentType "application/json" -TimeoutSec $TimeoutSeconds -MaximumRedirection 0 | Out-Null
    }
    catch {
        # Never let a raw Invoke-RestMethod exception (which can embed the
        # request URI - and therefore any query-string signature/secret - in
        # its Message/Response) escape this function. Persisted/log-visible
        # errors get only a fixed category, never the URL itself.
        $statusCode = $null
        try {
            $responseProp = $_.Exception.PSObject.Properties["Response"]
            if ($responseProp -and $responseProp.Value) { $statusCode = [int]$responseProp.Value.StatusCode }
        }
        catch { $statusCode = $null }
        $category = if ($statusCode) { "http-$statusCode" } else { "network-or-transport-error" }
        throw "Teams Workflows webhook delivery failed (category: $category). The webhook URL and any query-string secret are never included in this error."
    }
}

# ---------------------------------------------------------------------------
# -TestTeamsNotifications: operator-authorized connectivity/delivery probe.
# Distinct from -DryRun (never sends) and from the live reviewer (never
# reviews a PR). Reuses the SAME transport functions above - never a
# separate/parallel send path - so shadowing them in self-checks covers both.
# ---------------------------------------------------------------------------

function New-ReviewerTeamsTestNotificationHtml {
    <#
        The ONLY HTML this test path ever sends: a fixed, wrapper-built
        template with no model or prompt data and no local paths/secrets.
        Every dynamic value (destination label, timestamp) is bounded and
        passed through ConvertTo-ReviewerHtmlEncoded exactly like the live
        notification template. States explicitly that this is a test and
        that no pull request was reviewed.
    #>
    param(
        [Parameter(Mandatory)][string]$DeliveryMarker,
        [Parameter(Mandatory)][string]$DestinationLabel,
        [Parameter(Mandatory)][DateTime]$TimestampUtc
    )
    $encodedDestination = ConvertTo-ReviewerHtmlEncoded -Value $DestinationLabel -MaxLength 128
    $encodedTimestamp = ConvertTo-ReviewerHtmlEncoded -Value ($TimestampUtc.ToString("o")) -MaxLength 64
    $html = "<div>$($script:ReviewerTeamsAutomatedBanner)" +
        "<p><b>API Hub reviewer-agent Teams connectivity test.</b></p>" +
        "<p>This is a TEST message sent by -TestTeamsNotifications. No pull request was reviewed and no review outcome is implied.</p>" +
        "<p><b>Destination:</b> $encodedDestination</p>" +
        "<p><b>Sent (UTC):</b> $encodedTimestamp</p><!-- $DeliveryMarker --></div>"
    if ($html.Length -gt $script:ReviewerTeamsMaxHtmlLength) {
        # This fixed template has no unbounded input; exceeding the cap here
        # would indicate a template regression, not operator-controlled data.
        throw "Fixed test-notification HTML unexpectedly exceeded the length bound; refusing to send a malformed template."
    }
    return $html
}

function Invoke-ReviewerTeamsNotificationTest {
    <#
        Immediate, synchronous connectivity/delivery probe for
        -TestTeamsNotifications. Sends exactly one fixed test message to
        EVERY enabled destination in $TeamsConfig and returns a result per
        destination (Destination, Success, MessageId, Error) for the caller
        to print - it never throws for a single destination's failure so
        every enabled destination is always attempted.

        This is NOT a synthetic review event: it never calls
        Add-ReviewerTeamsNotification / Invoke-ReviewerTeamsNotificationDrain
        (no outbox/retry state is touched), never starts Copilot, and never
        reads or writes an ADO pull request. A WorkIQ MCP session is opened
        only when channel and/or directAuthor is enabled (a webhook-only
        configuration needs no session at all) and is always closed in
        `finally`, even if one destination throws.
    #>
    param(
        [Parameter(Mandatory)]$TeamsConfig,
        [AllowNull()][string]$TeamsTestRecipient
    )
    $results = New-Object System.Collections.Generic.List[pscustomobject]
    $needsSession = $TeamsConfig.ChannelEnabled -or $TeamsConfig.DirectAuthorEnabled
    $session = $null
    $sessionStartError = $null
    try {
        if ($needsSession) {
            try {
                $agencyCmd = Get-Command agency -ErrorAction SilentlyContinue
                if (-not $agencyCmd) {
                    throw "The 'agency' command was not found on PATH; the channel/directAuthor test destinations require the same 'agency mcp workiq' subprocess the live reviewer uses."
                }
                $session = New-AgencyWorkIqMcpSession -AgencyPath $agencyCmd.Source -Subcommand $TeamsConfig.WorkIqSubcommand -TimeoutSeconds $TeamsConfig.WorkIqTimeoutSeconds
            }
            catch {
                # Channel/directAuthor share WorkIQ, but the independent
                # Workflows webhook destination must still be tested.
                $sessionStartError = "WorkIQ session could not be started: $($_.Exception.Message)"
            }
        }
        $deadline = [DateTime]::UtcNow.AddSeconds($TeamsConfig.WorkIqTimeoutSeconds)

        if ($TeamsConfig.ChannelEnabled) {
            try {
                if (-not $session) { throw $sessionStartError }
                $html = New-ReviewerTeamsTestNotificationHtml -DeliveryMarker (New-ReviewerTeamsDeliveryMarker) -DestinationLabel "channel" -TimestampUtc ([DateTime]::UtcNow)
                $messageId = Send-ReviewerTeamsChannelMessage -Session $session -TeamId $TeamsConfig.ChannelTeamId -ChannelId $TeamsConfig.ChannelChannelId -Html $html -DeadlineUtc $deadline
                $results.Add([pscustomobject]@{ Destination = "channel"; Success = $true; MessageId = $messageId; Error = $null })
            }
            catch {
                $results.Add([pscustomobject]@{ Destination = "channel"; Success = $false; MessageId = $null; Error = $_.Exception.Message })
            }
        }

        if ($TeamsConfig.DirectAuthorEnabled) {
            try {
                if (-not $session) { throw $sessionStartError }
                if ([string]::IsNullOrWhiteSpace($TeamsTestRecipient)) {
                    throw "config.teamsNotifications.directAuthor is enabled but no -TeamsTestRecipient was supplied."
                }
                $html = New-ReviewerTeamsTestNotificationHtml -DeliveryMarker (New-ReviewerTeamsDeliveryMarker) -DestinationLabel "directAuthor ($TeamsTestRecipient)" -TimestampUtc ([DateTime]::UtcNow)
                $chatId = Resolve-ReviewerTeamsAuthorChatId -Session $session -AuthorUniqueName $TeamsTestRecipient -DeadlineUtc $deadline
                $messageId = Send-ReviewerTeamsChatMessage -Session $session -ChatId $chatId -Html $html -DeadlineUtc $deadline
                $results.Add([pscustomobject]@{ Destination = "directAuthor"; Success = $true; MessageId = $messageId; Error = $null })
            }
            catch {
                $results.Add([pscustomobject]@{ Destination = "directAuthor"; Success = $false; MessageId = $null; Error = $_.Exception.Message })
            }
        }

        if ($TeamsConfig.WebhookEnabled) {
            try {
                $html = New-ReviewerTeamsTestNotificationHtml -DeliveryMarker (New-ReviewerTeamsDeliveryMarker) -DestinationLabel "workflowsWebhook" -TimestampUtc ([DateTime]::UtcNow)
                Send-ReviewerTeamsWorkflowsWebhook -EnvironmentVariableName $TeamsConfig.WebhookEnvVarName -Html $html -TimeoutSeconds $TeamsConfig.WorkIqTimeoutSeconds
                $results.Add([pscustomobject]@{ Destination = "workflowsWebhook"; Success = $true; MessageId = "(accepted; Teams Workflows/Power Automate returns no message id)"; Error = $null })
            }
            catch {
                $results.Add([pscustomobject]@{ Destination = "workflowsWebhook"; Success = $false; MessageId = $null; Error = $_.Exception.Message })
            }
        }
    }
    finally {
        if ($session) { Close-AgencyAdoMcpSession -Session $session -Abort }
    }
    return , $results
}

# ---------------------------------------------------------------------------
# Outbox (wrapper-owned, atomic via the caller's Get-JsonState/Set-JsonState)
# ---------------------------------------------------------------------------

function Compress-ReviewerTeamsNotificationState {
    <#
        Replaces sent/failed-terminal records with minimal tombstones.
        Terminal keys are never evicted: retaining every exact key preserves
        idempotency without a time/count window that could permit an old
        logical event to be re-enqueued. Pending retry envelopes are never
        removed or altered. Failed tombstones retain a bounded error category
        for diagnostics.
    #>
    param([Parameter(Mandatory)][hashtable]$State)

    $changed = $false
    $nowText = [DateTime]::UtcNow.ToString("o")
    foreach ($key in @($State.Keys)) {
        $entry = $State[$key]
        $status = if ($entry.PSObject.Properties["status"]) { [string]$entry.status } else { $null }
        if ($status -notin @("sent", "failed-terminal")) { continue }

        $completedAtSource = if ($entry.PSObject.Properties["completedAt"] -and $entry.completedAt) {
            [string]$entry.completedAt
        }
        elseif ($entry.PSObject.Properties["sentAt"] -and $entry.sentAt) {
            [string]$entry.sentAt
        }
        else {
            $nowText
        }
        $parsedCompletedAt = [DateTimeOffset]::MinValue
        $completedAtParses = $completedAtSource.Length -le 64 -and
            [DateTimeOffset]::TryParse($completedAtSource, [ref]$parsedCompletedAt)
        $completedAtText = if ($completedAtParses) {
            $parsedCompletedAt.UtcDateTime.ToString("o")
        }
        else {
            $nowText
        }

        $tombstoneProperty = $entry.PSObject.Properties["tombstone"]
        $schemaProperty = $entry.PSObject.Properties["schemaVersion"]
        $lastErrorProperty = $entry.PSObject.Properties["lastError"]
        $propertyNames = @($entry.PSObject.Properties | ForEach-Object { $_.Name })
        $allowedPropertyNames = @("schemaVersion", "tombstone", "status", "completedAt", "lastError")
        $hasCanonicalProperties = $propertyNames.Count -eq $allowedPropertyNames.Count -and
            @($propertyNames | Where-Object { $allowedPropertyNames -cnotcontains $_ }).Count -eq 0
        $hasCanonicalLastError = (-not $lastErrorProperty) -or
            $null -eq $lastErrorProperty.Value -or
            ($lastErrorProperty.Value -is [string] -and $lastErrorProperty.Value.Length -le $script:ReviewerTeamsMaxFieldLength)
        $isTombstone = $hasCanonicalProperties -and
            $schemaProperty -and
            (Test-AgencyMcpStrictInt -Value $schemaProperty.Value -Min $script:ReviewerTeamsOutboxSchemaVersion -Max $script:ReviewerTeamsOutboxSchemaVersion) -and
            $tombstoneProperty.Value -is [bool] -and
            $tombstoneProperty.Value -eq $true -and
            $entry.PSObject.Properties["completedAt"] -and
            $entry.PSObject.Properties["completedAt"].Value -is [string] -and
            $completedAtParses -and
            $entry.PSObject.Properties["completedAt"].Value -ceq $completedAtText -and
            $hasCanonicalLastError
        if (-not $isTombstone) {
            $lastError = $null
            if ($status -eq "failed-terminal" -and $entry.PSObject.Properties["lastError"] -and $entry.lastError) {
                $lastError = [string]$entry.lastError
                if ($lastError.Length -gt $script:ReviewerTeamsMaxFieldLength) {
                    $lastError = $lastError.Substring(0, $script:ReviewerTeamsMaxFieldLength)
                }
            }
            $State[$key] = [ordered]@{
                schemaVersion  = $script:ReviewerTeamsOutboxSchemaVersion
                tombstone      = $true
                status         = $status
                completedAt    = $completedAtText
                lastError      = $lastError
            }
            $changed = $true
        }
    }
    return [pscustomobject]@{ State = $State; Changed = $changed }
}

function Add-ReviewerTeamsNotification {
    <#
        Enqueues one logical notification as "pending" BEFORE any external
        write is attempted. Re-adding the identical logical event (same
        destination/event/PR/commit/outcome) is a no-op once it is already
        sent - this is the enqueue-time half of idempotency; the drain-time
        half is the recent-messages marker scan (keyed on the random
        deliveryMarker generated here, never the deterministic event id).

        For DestinationKey "directAuthor" the caller MUST pass the exact
        validated ADO createdBy.uniqueName for the PR this event is about
        (AuthorUniqueName); this function fails closed (throws, enqueues
        nothing) if it is missing or does not look like a real UPN. This
        value is stored ON the entry and is the ONLY author ever used to
        resolve the one-on-one chat at drain time - a later drain running
        under a different cycle/PR context can never redirect this entry to
        a different author. channel/workflowsWebhook entries never depend on
        an author at all.
    #>
    param(
        [Parameter(Mandatory)][string]$StatePath,
        [Parameter(Mandatory)][string]$DestinationKey,
        [Parameter(Mandatory)][ValidateSet("startup", "shutdown", "reviewCompleted", "reviewFailed", "candidateStarved")][string]$Event,
        [AllowNull()][string]$PrId,
        [AllowNull()][string]$SourceCommit,
        [AllowNull()][string]$VoteOutcome,
        [AllowNull()][string]$AuthorUniqueName,
        [Parameter(Mandatory)][hashtable]$TemplateFields,
        [Parameter(Mandatory)][int]$MaxAttempts
    )
    if ($DestinationKey -eq "directAuthor" -and -not (Test-ReviewerTeamsAuthorUniqueName -AuthorUniqueName $AuthorUniqueName)) {
        throw "Refusing to enqueue a directAuthor Teams notification without an exact, validated ADO createdBy.uniqueName."
    }
    $eventId = Get-ReviewerTeamsEventId -DestinationKey $DestinationKey -Event $Event -PrId $PrId -SourceCommit $SourceCommit -VoteOutcome $VoteOutcome
    $key = "$eventId|$DestinationKey"
    $state = Get-JsonState -Path $StatePath
    if ($state.ContainsKey($key) -and $state[$key].PSObject.Properties["status"] -and [string]$state[$key].status -eq "sent") {
        return $eventId
    }
    $compaction = Compress-ReviewerTeamsNotificationState -State $state
    $state = $compaction.State
    if (-not $state.ContainsKey($key)) {
        $state[$key] = @{
            schemaVersion    = $script:ReviewerTeamsOutboxSchemaVersion
            eventId          = $eventId
            deliveryMarker   = (New-ReviewerTeamsDeliveryMarker)
            destinationKey   = $DestinationKey
            event            = $Event
            prId             = $PrId
            sourceCommit     = $SourceCommit
            voteOutcome      = $VoteOutcome
            authorUniqueName = $(if ($DestinationKey -eq "directAuthor") { $AuthorUniqueName } else { $null })
            templateFields   = $TemplateFields
            status           = "pending"
            attempts         = 0
            maxAttempts      = $MaxAttempts
            lastError        = $null
            nextAttemptAt    = (Get-Date).ToUniversalTime().ToString("o")
            createdAt        = (Get-Date).ToUniversalTime().ToString("o")
            sentAt           = $null
            sentMessageId    = $null
        }
        Set-JsonState -Path $StatePath -State $state
    }
    elseif ($compaction.Changed) {
        Set-JsonState -Path $StatePath -State $state
    }
    return $eventId
}

function Invoke-ReviewerTeamsNotificationDrain {
    <#
        Drains DUE pending entries (bounded per call). Every failure here is
        caught, recorded on the entry (attempts/backoff/lastError), and
        NEVER re-thrown - the caller in Start-ReviewerAgent.ps1 additionally
        wraps this in try/catch as defense in depth, but this function itself
        guarantees isolation so a broken Teams/WorkIQ path can never affect
        review/vote outcomes or the main loop.
    #>
    param(
        [Parameter(Mandatory)][string]$StatePath,
        [Parameter(Mandatory)]$Context
    )
    $state = Get-JsonState -Path $StatePath
    if ($null -eq $state -or $state.Count -eq 0) { return }
    $initialCompaction = Compress-ReviewerTeamsNotificationState -State $state
    $state = $initialCompaction.State
    if ($initialCompaction.Changed) {
        Set-JsonState -Path $StatePath -State $state
    }
    $now = [DateTime]::UtcNow

    # Determine due entries WITHOUT letting a single malformed/legacy entry's
    # nextAttemptAt cast throw out of this computation - a bad cast in a
    # shared Where-Object scriptblock would abort the entire filter (and thus
    # every other, possibly valid, entry) before the per-entry loop below
    # even starts. Each key is evaluated independently and a parse failure
    # fails ONLY that entry closed, right here, before it can wedge anything.
    $due = New-Object System.Collections.Generic.List[string]
    foreach ($key in @($state.Keys)) {
        if ($due.Count -ge $script:ReviewerTeamsMaxDrainPerCycle) { break }
        $entry = $state[$key]
        if (-not ($entry.PSObject.Properties["status"] -and [string]$entry.status -eq "pending")) { continue }
        try {
            $isDue = (-not $entry.PSObject.Properties["nextAttemptAt"]) -or ([DateTime]$entry.nextAttemptAt -le $now)
        }
        catch {
            $entry.status = "failed-terminal"
            $entry.lastError = "Malformed nextAttemptAt could not be parsed as a date; failed closed instead of blocking the drain."
            $state[$key] = $entry
            $terminalCompaction = Compress-ReviewerTeamsNotificationState -State $state
            $state = $terminalCompaction.State
            Set-JsonState -Path $StatePath -State $state
            continue
        }
        if ($isDue) { [void]$due.Add($key) }
    }

    foreach ($key in $due) {
        $entry = $state[$key]

        # Everything below - schema migration, required-property validation,
        # HTML build, and send - runs inside ONE per-entry try so a bad or
        # legacy entry can only ever fail itself closed; it can never throw
        # out to skip other due entries or the final state persistence below.
        try {
            # --- Fail-closed migration/validation gate (runs BEFORE any send) ---
            # Bound/validate the delivery marker read back from state; a legacy
            # (schema version 1) or corrupt entry never gets silently upgraded.
            $entrySchemaVersion = if ($entry.PSObject.Properties["schemaVersion"]) { [int]$entry.schemaVersion } else { 1 }
            $existingMarker = if ($entry.PSObject.Properties["deliveryMarker"]) { [string]$entry.deliveryMarker } else { $null }
            if (-not (Test-ReviewerTeamsDeliveryMarker -Marker $existingMarker)) {
                # channel/workflowsWebhook entries do not depend on an author, so
                # a missing/invalid marker on THOSE is safe to migrate. BEFORE
                # minting a brand-new (unguessable) v2 marker, check whether a
                # v1 send already succeeded but the local "sent" state write
                # failed to persist (the only reason a schema-v1 entry would
                # still be "pending" here) - by scanning for the LEGACY marker
                # (this entry's own bounded/validated eventId, which schema v1
                # embedded directly in the HTML), never the not-yet-generated
                # new one. A brand-new v2 marker cannot possibly appear in a
                # message a v1 send already posted, so checking against it
                # first (the pre-fix bug) can never detect a real prior send
                # and always reposts a duplicate.
                #
                # This legacy check is only meaningful for a destination that
                # supports reading back recent messages (channel today;
                # directAuthor never reaches here - see below). workflowsWebhook
                # has no read-back path in ANY schema version (a webhook is a
                # one-way POST), so a legacy webhook entry can never be proven
                # already-sent here; it falls through to a normal v2 send. That
                # is the documented, tested safe fallback for that one
                # destination - it is no worse than pre-existing webhook
                # behavior (which never deduped in either schema version), not
                # a regression, and this function must not pretend a
                # capability that schema v1 never had.
                if ($entry.destinationKey -ne "directAuthor") {
                    $legacyEventId = if ($entry.PSObject.Properties["eventId"]) { [string]$entry.eventId } else { $null }
                    $legacyEventIdValid = ($legacyEventId -is [string]) -and ($legacyEventId -cmatch $script:ReviewerTeamsLegacyEventIdPattern)
                    $legacyAlreadySent = $false
                    if ($legacyEventIdValid -and $entry.destinationKey -eq "channel") {
                        $legacyAlreadySent = Test-ReviewerTeamsRecentMessagesContainMarker -Session $Context.Session `
                            -Path $Context.DestinationPaths["channel"] -Marker $legacyEventId `
                            -DeadlineUtc ([DateTime]::UtcNow.AddSeconds($Context.WorkIqTimeoutSeconds))
                    }
                    $entry | Add-Member -NotePropertyName "deliveryMarker" -NotePropertyValue (New-ReviewerTeamsDeliveryMarker) -Force
                    $entry | Add-Member -NotePropertyName "schemaVersion" -NotePropertyValue $script:ReviewerTeamsOutboxSchemaVersion -Force
                    $entrySchemaVersion = $script:ReviewerTeamsOutboxSchemaVersion
                    if ($legacyAlreadySent) {
                        # A prior v1 send is confirmed via ITS OWN legacy
                        # marker - mark sent and do NOT post again. The fresh
                        # v2 marker was still persisted above (for schema
                        # consistency/future audit) but is never used to send
                        # or re-check; it plays no role in this dedupe result.
                        $entry.status = "sent"
                        $entry.sentAt = (Get-Date).ToUniversalTime().ToString("o")
                        $entry.sentMessageId = "deduped-legacy-v1"
                        $entry.lastError = $null
                        $state[$key] = $entry
                        $terminalCompaction = Compress-ReviewerTeamsNotificationState -State $state
                        $state = $terminalCompaction.State
                        Set-JsonState -Path $StatePath -State $state
                        continue
                    }
                    $state[$key] = $entry
                    $finalCompaction = Compress-ReviewerTeamsNotificationState -State $state
                    Set-JsonState -Path $StatePath -State $finalCompaction.State
                }
                else {
                    $entry.status = "failed-terminal"
                    $entry.lastError = "Legacy/corrupt directAuthor outbox entry has no valid delivery marker; failed closed rather than migrated silently."
                    $state[$key] = $entry
                    $terminalCompaction = Compress-ReviewerTeamsNotificationState -State $state
                    $state = $terminalCompaction.State
                    Set-JsonState -Path $StatePath -State $state
                    continue
                }
            }
            # directAuthor entries must carry their OWN validated author,
            # captured at enqueue time - never fall back to the current drain
            # cycle's Context.AuthorUniqueName, which belongs to whatever PR
            # happens to be under review THIS cycle, not necessarily the PR this
            # entry was enqueued for. A legacy (pre-schema-2) or missing/invalid
            # author fails ONLY this entry closed; it is never silently routed.
            if ($entry.destinationKey -eq "directAuthor") {
                $entryAuthor = if ($entry.PSObject.Properties["authorUniqueName"]) { [string]$entry.authorUniqueName } else { $null }
                if ($entrySchemaVersion -lt 2 -or -not (Test-ReviewerTeamsAuthorUniqueName -AuthorUniqueName $entryAuthor)) {
                    $entry.status = "failed-terminal"
                    $entry.lastError = "Legacy or missing/invalid stored author on a directAuthor entry; failed closed instead of routing to the current cycle's author."
                    $state[$key] = $entry
                    $terminalCompaction = Compress-ReviewerTeamsNotificationState -State $state
                    $state = $terminalCompaction.State
                    Set-JsonState -Path $StatePath -State $state
                    continue
                }
            }

            $html = New-ReviewerTeamsNotificationHtml -DeliveryMarker ([string]$entry.deliveryMarker) -Event ([string]$entry.event) `
                -Repository ([string]$entry.templateFields.repository) `
                -PrId $(if ($entry.templateFields.PSObject.Properties["prId"] -and $entry.templateFields.prId) { [int]$entry.templateFields.prId } else { $null }) `
                -PrLink ([string]$entry.templateFields.prLink) -Commit ([string]$entry.templateFields.commit) `
                -Findings ([string]$entry.templateFields.findings) -Recommendation ([string]$entry.templateFields.recommendation) `
                -RequestedVote ([string]$entry.templateFields.requestedVote) -VoteOutcome ([string]$entry.voteOutcome)

            $sentMessageId = $null
            if ($entry.destinationKey -eq "workflowsWebhook") {
                Send-ReviewerTeamsWorkflowsWebhook -EnvironmentVariableName $Context.WorkflowsWebhookEnvVarName -Html $html -TimeoutSeconds $Context.WorkIqTimeoutSeconds
                $sentMessageId = "webhook"
            }
            elseif ($entry.destinationKey -eq "channel") {
                $path = $Context.DestinationPaths["channel"]
                $alreadySent = Test-ReviewerTeamsRecentMessagesContainMarker -Session $Context.Session -Path $path `
                    -Marker ([string]$entry.deliveryMarker) -DeadlineUtc ([DateTime]::UtcNow.AddSeconds($Context.WorkIqTimeoutSeconds))
                if ($alreadySent) {
                    $sentMessageId = "deduped-existing"
                }
                else {
                    $sentMessageId = Send-ReviewerTeamsChannelMessage -Session $Context.Session -TeamId $Context.TeamId -ChannelId $Context.ChannelId `
                        -Html $html -DeadlineUtc ([DateTime]::UtcNow.AddSeconds($Context.WorkIqTimeoutSeconds))
                }
            }
            else {
                # directAuthor: resolve (or reuse-via-Graph-guarantee) the
                # one-on-one chat FIRST, then dedupe-check/post against its
                # actual message path - there is no fixed path to scan until
                # the chat id is known. AuthorUniqueName comes from the
                # entry itself (validated above), never from $Context.
                $chatId = Resolve-ReviewerTeamsAuthorChatId -Session $Context.Session -AuthorUniqueName ([string]$entry.authorUniqueName) `
                    -DeadlineUtc ([DateTime]::UtcNow.AddSeconds($Context.WorkIqTimeoutSeconds))
                $chatPath = "/chats/$chatId/messages"
                $alreadySent = Test-ReviewerTeamsRecentMessagesContainMarker -Session $Context.Session -Path $chatPath `
                    -Marker ([string]$entry.deliveryMarker) -DeadlineUtc ([DateTime]::UtcNow.AddSeconds($Context.WorkIqTimeoutSeconds))
                if ($alreadySent) {
                    $sentMessageId = "deduped-existing"
                }
                else {
                    $sentMessageId = Send-ReviewerTeamsChatMessage -Session $Context.Session -ChatId $chatId -Html $html `
                        -DeadlineUtc ([DateTime]::UtcNow.AddSeconds($Context.WorkIqTimeoutSeconds))
                }
            }
            $entry.status = "sent"
            $entry.sentAt = (Get-Date).ToUniversalTime().ToString("o")
            $entry.sentMessageId = [string]$sentMessageId
            $entry.lastError = $null
        }
        catch {
            $deliveryError = $_.Exception.Message
            try {
                $currentAttempts = 0
                $parsedAttempts = 0
                if ($entry.PSObject.Properties["attempts"] -and
                    [int]::TryParse([string]$entry.attempts, [ref]$parsedAttempts) -and
                    $parsedAttempts -ge 0) {
                    $currentAttempts = $parsedAttempts
                }

                $maxAttempts = 1
                $parsedMaxAttempts = 0
                if ($entry.PSObject.Properties["maxAttempts"] -and
                    [int]::TryParse([string]$entry.maxAttempts, [ref]$parsedMaxAttempts) -and
                    $parsedMaxAttempts -ge 1) {
                    $maxAttempts = $parsedMaxAttempts
                }

                $attempts = if ($currentAttempts -lt [int]::MaxValue) { $currentAttempts + 1 } else { [int]::MaxValue }
                $entry | Add-Member -NotePropertyName "attempts" -NotePropertyValue $attempts -Force
                $entry | Add-Member -NotePropertyName "maxAttempts" -NotePropertyValue $maxAttempts -Force
                $entry | Add-Member -NotePropertyName "lastError" -NotePropertyValue $deliveryError -Force
                if ($attempts -ge $maxAttempts) {
                    $entry | Add-Member -NotePropertyName "status" -NotePropertyValue "failed-terminal" -Force
                }
                else {
                    $backoffSeconds = [Math]::Min($Context.MaxBackoffSeconds, $Context.MinBackoffSeconds * [Math]::Pow(2, $attempts - 1))
                    $entry | Add-Member -NotePropertyName "nextAttemptAt" -NotePropertyValue ([DateTime]::UtcNow.AddSeconds($backoffSeconds).ToString("o")) -Force
                }
            }
            catch {
                # Even a badly malformed retry envelope must fail only itself.
                # Replacing it with a minimal terminal record keeps the shared
                # outbox writable so later valid entries can still progress.
                $entry = [pscustomobject]@{
                    status      = "failed-terminal"
                    attempts    = 1
                    maxAttempts = 1
                    lastError   = "Malformed notification retry state failed closed."
                }
            }
        }
        $state[$key] = $entry
        $entryCompaction = Compress-ReviewerTeamsNotificationState -State $state
        $state = $entryCompaction.State
    }
    $finalCompaction = Compress-ReviewerTeamsNotificationState -State $state
    Set-JsonState -Path $StatePath -State $finalCompaction.State
}
