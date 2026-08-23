#Requires -Version 7.0

<#
    Versioned generalist model response envelope, version 2.

    WHY THIS EXISTS
    ---------------
    The v1 contract asked one model message to be a single line carrying one
    JSON object that mixed wrapper-owned bindings (pr/repo/project/hash) with
    model-owned content, and closed with a trailing `nonce` field. Models that
    did the review correctly kept emitting valid JSON that simply omitted the
    trailing nonce. Strict v1 then rejected the whole line, and with it the
    entire pass: no findings, no vote, and - worse - no census. A pass that
    produced a complete, honest review was recorded as if the model had never
    answered.

    V2 splits the two things v1 conflated:

      * a STANDALONE nonce challenge line, which is the only anti-replay
        credential, and
      * a payload line carrying ONLY model-owned content plus the one binding
        the model must prove it read (`reviewedSourceCommit`).

    Losing the challenge line now costs the pass its VOTE, not its evidence.
    That is the whole point of the two auth tiers below.

    WHAT THIS FILE OWNS
    -------------------
      * the v2 payload schema and its bounds,
      * extraction from the CLI's ordered assistant.message events (never from
        prompt/tool/result/stderr text), with an explicit, narrow raw-stdout
        fallback,
      * the auth-tier decision (`authenticated` / `evidenceOnly` / `none`),
      * the wrapper-owned `reviewer-result-envelope.v2` document, its
        domain-separated HMAC seal and inventory, and strict version dispatch,
      * the run-key path startup self-check.

    WHAT THIS FILE DELIBERATELY DOES NOT DO
    ---------------------------------------
      * It never trusts a wrapper-owned field that arrived from the model. Every
        binding in the envelope is copied from the wrapper's own state; the
        payload's closed key set makes it impossible for the model to supply one.
      * It never re-injects the expected nonce into the model's payload to make
        it validate. `nonceObserved` records what the model actually emitted, or
        null. There is no code path that writes the expected nonce into a
        model-derived object.
#>

Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Contract constants
# ---------------------------------------------------------------------------

$script:ReviewerResponseNoncePrefixV2 = 'REVIEWER_NONCE_V2:'
$script:ReviewerResponsePayloadPrefixV2 = 'REVIEWER_PAYLOAD_V2:'
$script:ReviewerResponseEnvelopeKindV2 = 'reviewer-result-envelope.v2'
$script:ReviewerResponseEnvelopeSchemaVersionV2 = 2
$script:ReviewerResponsePayloadSchemaVersionV2 = 2

# The v1 marker prefix, retained ONLY so version dispatch can recognize and
# refuse a v1 document rather than mis-read it as a v2 one.
$script:ReviewerResponseMarkerPrefixV1 = 'REVIEWER_RESULT_V1:'
$script:ReviewerResponseEnvelopeKindV1 = 'reviewer-result-envelope.v1'

# The payload's own key set, in the order the contract states it. The order is
# documented and emitted; the parser compares the key SET exactly (a closed
# object) and does not depend on order, because a model that reorders keys has
# still answered the question and a byte-order rule would recreate exactly the
# brittleness v2 exists to remove.
$script:ReviewerResponsePayloadKeysV2 = [string[]]@(
    'schemaVersion', 'reviewedSourceCommit', 'findings', 'recommendedVote', 'summary')

$script:ReviewerResponseFindingKeysV2 = [string[]]@('severity', 'filePath', 'line', 'comment')
$script:ReviewerResponseSeveritiesV2 = [string[]]@('critical', 'important', 'suggestion')
$script:ReviewerResponseVotesV2 = [string[]]@('approve', 'approveWithSuggestions', 'waitForAuthor', 'none')

# Bounds. The payload byte cap is deliberately >= the v1 marker's own hard
# output cap (196608 bytes) so that no answer that was legal under v1 becomes
# illegal under v2 - a shrinking bound would be a silent new way to lose a
# complete review.
$script:ReviewerResponseMaxPayloadBytesV2 = 262144      # 256 KiB
$script:ReviewerResponseMaxFieldBytesV2 = 8192          # per string field
$script:ReviewerResponseMaxFindingItemsV2 = 12
# The wrapper's own -MaxFindings ceiling. A run may raise its finding bound this
# far; anything above it is refused before a model is launched, under v1 and v2
# alike, so the two contracts admit exactly the same legal answers.
$script:ReviewerResponseMaxFindingCeilingV2 = 25
$script:ReviewerResponseMaxSummaryBytesV2 = 6144
$script:ReviewerResponseMaxOccurrencesV2 = 16           # retained nonce/payload occurrences
$script:ReviewerResponseMaxAssistantMessagesV2 = 512
$script:ReviewerResponseScanWindowCharsV2 = 262144

# Reason codes. `ok` is the only accepting value. Everything else names exactly
# what went wrong, so no caller has to match prose.
$script:ReviewerResponseReasonV2 = @{
    Ok                   = 'ok'
    MissingPayload       = 'missingPayload'
    MalformedPayload     = 'malformedPayload'
    NonObjectPayload     = 'nonObjectPayload'
    TruncatedPayload     = 'truncatedPayload'
    PayloadOverflow      = 'payloadOverflow'
    PayloadSchemaInvalid = 'payloadSchemaInvalid'
    ConflictingPayload   = 'conflictingPayload'
    ConflictingNonce     = 'conflictingNonce'
    WrongNonce           = 'wrongNonce'
    WrongSourceCommit    = 'wrongSourceCommit'
    VoteInvariant        = 'voteInvariantViolated'
    NoAssistantEvents    = 'noAssistantEvents'
    EventShapeCanary     = 'eventShapeCanaryFailed'
}

$script:ReviewerResponseAuthTierV2 = @{
    Authenticated = 'authenticated'
    EvidenceOnly  = 'evidenceOnly'
    None          = 'none'
}

$script:ReviewerResponseUtf8 = [System.Text.UTF8Encoding]::new($false, $true)

# ---------------------------------------------------------------------------
# Small shared helpers
# ---------------------------------------------------------------------------

function Get-ReviewerResponseProperty {
    <# StrictMode-safe optional property read: returns $Default when the object
       is null, is not a PSCustomObject, or simply has no such member. #>
    param([AllowNull()]$Object, [Parameter(Mandatory)][string]$Name, $Default = $null)

    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $Default
    }
    $property = $Object.PSObject.Properties[$Name]
    if (-not $property) { return $Default }
    return $property.Value
}

function Get-ReviewerResponseTextSha256 {
    <# SHA-256 of UTF-8 text, lowercase hex. Null text hashes to the empty
       string's digest rather than throwing, so an absent channel still gets a
       stable, comparable value in the envelope. #>
    param([AllowNull()][AllowEmptyString()][string]$Text)

    $bytes = $script:ReviewerResponseUtf8.GetBytes([string]$Text)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

function ConvertTo-ReviewerResponseCanonicalJson {
    <#
        Deterministic rendering of a parsed JSON value: object keys sorted
        ordinally, array order preserved, strings re-encoded through
        ConvertTo-Json so escaping is normalized.

        Used for exactly one thing in extraction: deciding whether two payload
        occurrences are the SAME payload. The contract says duplicate payloads
        must be "canonical-byte-identical", which is this text compared with
        -cne. Two renderings of one answer (a compact final line and a fenced
        pretty copy in the closing prose) therefore agree; two payloads that say
        different things do not, and that pair is terminal.
    #>
    param([AllowNull()]$Value, [int]$Depth = 0)

    if ($Depth -gt 24) { throw "The v2 payload exceeded the maximum canonical depth." }
    if ($null -eq $Value) { return 'null' }
    if ($Value -is [bool]) { if ($Value) { return 'true' } else { return 'false' } }
    if ($Value -is [string]) { return (ConvertTo-Json -InputObject $Value -Depth 1 -Compress) }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [decimal]) {
        return [Convert]::ToString($Value, [Globalization.CultureInfo]::InvariantCulture)
    }
    if ($Value -is [double] -or $Value -is [single]) {
        return ([double]$Value).ToString('R', [Globalization.CultureInfo]::InvariantCulture)
    }
    if ($Value -is [datetime]) {
        return (ConvertTo-Json -InputObject ([datetime]$Value).ToUniversalTime().ToString('o') -Depth 1 -Compress)
    }
    if ($Value -is [System.Collections.IDictionary]) {
        $names = [string[]]@([string[]]@($Value.Keys) | Sort-Object -CaseSensitive)
        $parts = [System.Collections.Generic.List[string]]::new()
        foreach ($name in $names) {
            [void]$parts.Add((ConvertTo-Json -InputObject $name -Depth 1 -Compress) + ':' +
                (ConvertTo-ReviewerResponseCanonicalJson -Value $Value[$name] -Depth ($Depth + 1)))
        }
        return '{' + ($parts -join ',') + '}'
    }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $names = [string[]]@([string[]]@($Value.PSObject.Properties.Name) | Sort-Object -CaseSensitive)
        $parts = [System.Collections.Generic.List[string]]::new()
        foreach ($name in $names) {
            [void]$parts.Add((ConvertTo-Json -InputObject $name -Depth 1 -Compress) + ':' +
                (ConvertTo-ReviewerResponseCanonicalJson -Value $Value.PSObject.Properties[$name].Value -Depth ($Depth + 1)))
        }
        return '{' + ($parts -join ',') + '}'
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $parts = [System.Collections.Generic.List[string]]::new()
        foreach ($item in $Value) {
            [void]$parts.Add((ConvertTo-ReviewerResponseCanonicalJson -Value $item -Depth ($Depth + 1)))
        }
        return '[' + ($parts -join ',') + ']'
    }
    throw "The v2 payload contained an unsupported JSON type '$($Value.GetType().FullName)'."
}

function Test-ReviewerResponseStrictInt {
    <# A JSON integer, not a string that looks like one and not a fraction. #>
    param([AllowNull()]$Value, [long]$Min, [long]$Max)

    if ($null -eq $Value) { return $false }
    if ($Value -is [bool] -or $Value -is [string]) { return $false }
    if ($Value -is [double] -or $Value -is [single] -or $Value -is [decimal]) {
        if ([double]$Value -ne [Math]::Floor([double]$Value)) { return $false }
    }
    elseif ($Value -isnot [int] -and $Value -isnot [long] -and $Value -isnot [int16] -and $Value -isnot [byte]) {
        return $false
    }
    $parsed = [long]0
    if (-not [long]::TryParse(([string]$Value), [ref]$parsed)) { return $false }
    return ($parsed -ge $Min -and $parsed -le $Max)
}

# ---------------------------------------------------------------------------
# The v2 payload schema
# ---------------------------------------------------------------------------

function Get-ReviewerResponsePayloadSchemaV2 {
    <#
        The closed model-owned payload contract.

        No wrapper-owned PR/repository/project/hash field appears here, by
        design: v1's habit of asking the model to retype wrapper state is what
        made a correct review rejectable for a clerical reason. The single
        binding the model must still prove is `reviewedSourceCommit` - the
        commit it claims to have read - and the parser compares that against the
        wrapper's own bound commit rather than believing it.
    #>
    param(
        [int]$MaxFindingItems = $script:ReviewerResponseMaxFindingItemsV2,
        [int]$MaxFieldBytes = $script:ReviewerResponseMaxFieldBytesV2,
        [int]$MaxSummaryBytes = $script:ReviewerResponseMaxSummaryBytesV2
    )

    return @{
        Keys   = [string[]]@($script:ReviewerResponsePayloadKeysV2)
        Fields = @{
            schemaVersion        = @{ Type = 'int'; Min = $script:ReviewerResponsePayloadSchemaVersionV2; Max = $script:ReviewerResponsePayloadSchemaVersionV2 }
            reviewedSourceCommit = @{ Type = 'hex'; Length = 40 }
            findings             = @{
                Type     = 'objectArray'
                MaxItems = $MaxFindingItems
                Item     = @{
                    Keys   = [string[]]@($script:ReviewerResponseFindingKeysV2)
                    Fields = @{
                        severity = @{ Type = 'enum'; Values = [string[]]@($script:ReviewerResponseSeveritiesV2) }
                        # The character bounds match the v1 marker schema exactly.
                        # A byte bound alone is not enough: the accepted content is
                        # later rebuilt into a v1 marker and re-parsed under v1's
                        # own limits, so anything v2 accepts that v1 refuses would
                        # be discarded a stage later, taking the whole cycle with
                        # it rather than one retryable attempt.
                        filePath = @{ Type = 'string'; MaxLength = 400; MaxBytes = 1200; AllowEmpty = $true; Pattern = '^(/[^\\:*?"<>|]*)?$' }
                        line     = @{ Type = 'int'; Min = 0; Max = 1000000 }
                        comment  = @{ Type = 'string'; MaxLength = 1200; MaxBytes = $MaxFieldBytes }
                    }
                }
            }
            recommendedVote      = @{ Type = 'enum'; Values = [string[]]@($script:ReviewerResponseVotesV2) }
            summary              = @{ Type = 'string'; MaxLength = 1500; MaxBytes = $MaxSummaryBytes; AllowEmpty = $true }
        }
    }
}

function Test-ReviewerResponseFieldValue {
    <#
        Typed, bounded validation of one payload field. Returns
        @{ Ok; Value; Reason; Field }. `Reason` is a v2 reason code so a caller
        can distinguish an over-cap field (overflow) from a wrong-shaped one
        (schema invalid) without matching text.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Spec,
        [AllowNull()]$Value,
        [Parameter(Mandatory)][string]$Path
    )

    $bad = {
        param([string]$Reason)
        return @{ Ok = $false; Value = $null; Reason = $Reason; Field = $Path }
    }
    switch ([string]$Spec.Type) {
        'int' {
            $min = if ($Spec.ContainsKey('Min')) { [long]$Spec.Min } else { [long][int]::MinValue }
            $max = if ($Spec.ContainsKey('Max')) { [long]$Spec.Max } else { [long][int]::MaxValue }
            if (-not (Test-ReviewerResponseStrictInt -Value $Value -Min $min -Max $max)) {
                return (& $bad $script:ReviewerResponseReasonV2.PayloadSchemaInvalid)
            }
            return @{ Ok = $true; Value = [int]$Value; Reason = ''; Field = $Path }
        }
        'hex' {
            if ($Value -isnot [string]) { return (& $bad $script:ReviewerResponseReasonV2.PayloadSchemaInvalid) }
            $length = [int]$Spec.Length
            if ([string]$Value -notmatch ('^[0-9a-fA-F]{' + $length + '}$')) {
                return (& $bad $script:ReviewerResponseReasonV2.PayloadSchemaInvalid)
            }
            return @{ Ok = $true; Value = ([string]$Value).ToLowerInvariant(); Reason = ''; Field = $Path }
        }
        'enum' {
            if ($Value -isnot [string]) { return (& $bad $script:ReviewerResponseReasonV2.PayloadSchemaInvalid) }
            if ([string[]]@($Spec.Values) -cnotcontains [string]$Value) {
                return (& $bad $script:ReviewerResponseReasonV2.PayloadSchemaInvalid)
            }
            return @{ Ok = $true; Value = [string]$Value; Reason = ''; Field = $Path }
        }
        'string' {
            if ($Value -isnot [string]) { return (& $bad $script:ReviewerResponseReasonV2.PayloadSchemaInvalid) }
            $text = [string]$Value
            $allowEmpty = $Spec.ContainsKey('AllowEmpty') -and [bool]$Spec.AllowEmpty
            if (-not $allowEmpty -and $text.Trim() -eq '') {
                return (& $bad $script:ReviewerResponseReasonV2.PayloadSchemaInvalid)
            }
            # Control characters would be handed straight to a provider as a
            # thread location or body, so they are refused here rather than
            # sanitized somewhere further downstream. TAB, CR and LF are refused
            # with the rest: the v1 marker schema this content is later rebuilt
            # into refuses them, and a value accepted here but rejected there
            # would lose the whole cycle instead of one retryable attempt.
            if ($text -match '[\x00-\x1f\x7f]') {
                return (& $bad $script:ReviewerResponseReasonV2.PayloadSchemaInvalid)
            }
            if ($Spec.ContainsKey('MaxLength') -and $text.Length -gt [int]$Spec.MaxLength) {
                return (& $bad $script:ReviewerResponseReasonV2.PayloadOverflow)
            }
            if ($Spec.ContainsKey('Pattern') -and $text -notmatch [string]$Spec.Pattern) {
                return (& $bad $script:ReviewerResponseReasonV2.PayloadSchemaInvalid)
            }
            if ($Spec.ContainsKey('MaxBytes')) {
                $bytes = $script:ReviewerResponseUtf8.GetByteCount($text)
                if ($bytes -gt [int]$Spec.MaxBytes) {
                    return (& $bad $script:ReviewerResponseReasonV2.PayloadOverflow)
                }
            }
            return @{ Ok = $true; Value = $text; Reason = ''; Field = $Path }
        }
        'objectArray' {
            if ($null -eq $Value -or $Value -is [string] -or
                $Value -is [System.Management.Automation.PSCustomObject] -or
                $Value -isnot [System.Collections.IEnumerable]) {
                return (& $bad $script:ReviewerResponseReasonV2.PayloadSchemaInvalid)
            }
            $items = [object[]]@($Value)
            $maxItems = if ($Spec.ContainsKey('MaxItems')) { [int]$Spec.MaxItems } else { 25 }
            if ($items.Count -gt $maxItems) {
                return (& $bad $script:ReviewerResponseReasonV2.PayloadOverflow)
            }
            $itemKeys = [string[]]@($Spec.Item.Keys)
            $converted = [System.Collections.Generic.List[object]]::new()
            for ($i = 0; $i -lt $items.Count; $i++) {
                $item = $items[$i]
                if ($item -isnot [System.Management.Automation.PSCustomObject]) {
                    return @{ Ok = $false; Value = $null
                        Reason = $script:ReviewerResponseReasonV2.PayloadSchemaInvalid; Field = "$Path[$i]" }
                }
                $actual = [string[]]@($item.PSObject.Properties.Name)
                foreach ($name in $actual) {
                    if ($itemKeys -cnotcontains $name) {
                        return @{ Ok = $false; Value = $null
                            Reason = $script:ReviewerResponseReasonV2.PayloadSchemaInvalid; Field = "$Path[$i].$name" }
                    }
                }
                $record = [ordered]@{}
                foreach ($name in $itemKeys) {
                    if (-not $item.PSObject.Properties[$name]) {
                        return @{ Ok = $false; Value = $null
                            Reason = $script:ReviewerResponseReasonV2.PayloadSchemaInvalid; Field = "$Path[$i].$name" }
                    }
                    $inner = Test-ReviewerResponseFieldValue -Spec ([hashtable]$Spec.Item.Fields[$name]) `
                        -Value $item.PSObject.Properties[$name].Value -Path "$Path[$i].$name"
                    if (-not $inner.Ok) { return $inner }
                    $record[$name] = $inner.Value
                }
                [void]$converted.Add([pscustomobject]$record)
            }
            return @{ Ok = $true; Value = [object[]]@($converted.ToArray()); Reason = ''; Field = $Path }
        }
        default { throw "The v2 payload schema declared an unknown field type '$($Spec.Type)'." }
    }
}

function Test-ReviewerResponsePayloadV2 {
    <#
        Validates one parsed payload object against the closed v2 schema and
        returns @{ Ok; Payload; Findings; Reason; Field; Detail }.

        The returned payload is REBUILT from validated values in contract key
        order. Nothing the model emitted survives unvalidated, and no key the
        contract does not name can survive at all - which is what makes "the
        wrapper does not trust wrapper-owned fields from the model" a structural
        property rather than a review comment.
    #>
    param(
        [Parameter(Mandatory)]$Parsed,
        [hashtable]$Schema
    )

    if (-not $Schema) { $Schema = Get-ReviewerResponsePayloadSchemaV2 }
    if ($Parsed -isnot [System.Management.Automation.PSCustomObject]) {
        return @{ Ok = $false; Payload = $null; Findings = [object[]]@()
            Reason = $script:ReviewerResponseReasonV2.NonObjectPayload; Field = ''
            Detail = 'The v2 payload was not a JSON object.'
        }
    }
    $allowed = [string[]]@($Schema.Keys)
    $actual = [string[]]@($Parsed.PSObject.Properties.Name)
    foreach ($name in $actual) {
        if ($allowed -cnotcontains $name) {
            return @{ Ok = $false; Payload = $null; Findings = [object[]]@()
                Reason = $script:ReviewerResponseReasonV2.PayloadSchemaInvalid; Field = $name
                Detail = "The v2 payload carried the unexpected key '$name'; the payload object is closed."
            }
        }
    }
    foreach ($name in $allowed) {
        if (-not $Parsed.PSObject.Properties[$name]) {
            return @{ Ok = $false; Payload = $null; Findings = [object[]]@()
                Reason = $script:ReviewerResponseReasonV2.PayloadSchemaInvalid; Field = $name
                Detail = "The v2 payload omitted the required key '$name'."
            }
        }
    }
    $record = [ordered]@{}
    $findings = [object[]]@()
    foreach ($name in $allowed) {
        $spec = [hashtable]$Schema.Fields[$name]
        $converted = Test-ReviewerResponseFieldValue -Spec $spec `
            -Value $Parsed.PSObject.Properties[$name].Value -Path $name
        if (-not $converted.Ok) {
            return @{ Ok = $false; Payload = $null; Findings = [object[]]@()
                Reason = [string]$converted.Reason; Field = [string]$converted.Field
                Detail = "The v2 payload field '$($converted.Field)' failed its typed schema rule."
            }
        }
        if ($name -ceq 'findings') {
            $findings = [object[]]@($converted.Value)
            $record[$name] = $findings
            continue
        }
        $record[$name] = $converted.Value
    }
    return @{ Ok = $true; Payload = [pscustomobject]$record; Findings = $findings
        Reason = $script:ReviewerResponseReasonV2.Ok; Field = ''; Detail = ''
    }
}

function Get-ReviewerResponseSeverityCounts {
    <# Wrapper-derived severity counts. Vote policy reads THESE, never a count
       the model stated about itself. #>
    param([AllowNull()][object[]]$Findings)

    $counts = [ordered]@{}
    foreach ($severity in $script:ReviewerResponseSeveritiesV2) { $counts[$severity] = 0 }
    foreach ($finding in [object[]]@($Findings)) {
        if ($null -eq $finding) { continue }
        $severity = [string](Get-ReviewerResponseProperty -Object $finding -Name 'severity' -Default '')
        if ($counts.Contains($severity)) { $counts[$severity] = [int]$counts[$severity] + 1 }
    }
    return [pscustomobject]$counts
}

function Test-ReviewerResponseVoteInvariant {
    <#
        Vote safety, decided from WRAPPER-DERIVED counts.

        Two refusals, both terminal:

          * an approving vote alongside a critical or important finding. The
            model cannot both say "this is blocking" and "ship it"; whichever
            half is wrong, the wrapper must not act on either.
          * the empty-string vote placeholder. v1's scaffold seeded
            `recommendedVote` with "" as a fill-me-in marker, and an unedited
            scaffold is precisely the case that must never reach a real vote.
            The v2 enum does not admit "", and this states why in its own code.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$RecommendedVote,
        [AllowNull()][object[]]$Findings
    )

    $counts = Get-ReviewerResponseSeverityCounts -Findings $Findings
    if ([string]::IsNullOrEmpty($RecommendedVote)) {
        return @{ Ok = $false; Reason = $script:ReviewerResponseReasonV2.VoteInvariant
            Detail = 'The payload carried the empty vote placeholder, which is never a decided vote.'
            SeverityCounts = $counts
        }
    }
    if ($script:ReviewerResponseVotesV2 -cnotcontains $RecommendedVote) {
        return @{ Ok = $false; Reason = $script:ReviewerResponseReasonV2.VoteInvariant
            Detail = "The payload recommended the unknown vote '$RecommendedVote'."
            SeverityCounts = $counts
        }
    }
    $blocking = [int]$counts.critical + [int]$counts.important
    if ($RecommendedVote -ceq 'approve' -and $blocking -gt 0) {
        return @{ Ok = $false; Reason = $script:ReviewerResponseReasonV2.VoteInvariant
            Detail = ("The payload recommended 'approve' while reporting $($counts.critical) critical and " +
                "$($counts.important) important finding(s); the wrapper-derived counts decide this, not the prose.")
            SeverityCounts = $counts
        }
    }
    return @{ Ok = $true; Reason = $script:ReviewerResponseReasonV2.Ok; Detail = ''; SeverityCounts = $counts }
}

# ---------------------------------------------------------------------------
# Assistant-event reading and the event-shape canary
# ---------------------------------------------------------------------------

function Get-ReviewerResponseAssistantEvents {
    <#
        The ordered, non-ephemeral assistant.message contents from the CLI's
        JSONL stdout, plus a canary describing the SHAPE of the stream.

        Only `assistant.message` is read. `assistant.message_delta` events are
        streaming fragments of a message that also arrives whole, so counting
        them would double every occurrence and turn one answer into an
        "ambiguous" pair. Prompt echoes, tool requests, tool results, `result`
        events and stderr are never read for content at all: a payload that
        arrives on any of those channels is something the wrapper or the
        environment said, not something the model answered, and admitting it
        would be an injection channel.

        An event is EPHEMERAL when it carries `data.ephemeral = true`. Builds
        that never set the field emit nothing ephemeral, which is why the flag
        is read as an optional property and defaults to false rather than being
        required.

        The canary exists because this parser's correctness depends on a shape
        the CLI is free to change under us. It records what was actually seen -
        JSON at all, assistant events, phase fields, model fields, how many
        distinct models - so a live fixture test can assert the shape and a real
        run can record it in the envelope instead of silently mis-reading a new
        stream.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$StdOutText,
        [int]$MaxMessages = $script:ReviewerResponseMaxAssistantMessagesV2
    )

    $messages = [System.Collections.Generic.List[string]]::new()
    $models = [System.Collections.Generic.List[string]]::new()
    $phases = [System.Collections.Generic.List[string]]::new()
    $ephemeralSkipped = 0
    $deltaEvents = 0
    $toolEvents = 0
    $resultEvents = 0
    $jsonLines = 0
    $unparsedLines = 0
    $typedEvents = 0
    $truncatedAt = $null

    foreach ($line in ([string]$StdOutText -split "`r?`n")) {
        $trimmed = "$line".Trim()
        if ($trimmed.Length -lt 2 -or -not $trimmed.StartsWith('{', [StringComparison]::Ordinal)) { continue }
        $jsonLines++
        $event = $null
        try { $event = $trimmed | ConvertFrom-Json -Depth 64 -ErrorAction Stop }
        catch { $unparsedLines++; continue }
        if ($event -isnot [System.Management.Automation.PSCustomObject]) { $unparsedLines++; continue }
        $typeProperty = $event.PSObject.Properties['type']
        if (-not $typeProperty) { $unparsedLines++; continue }
        $typedEvents++
        $eventType = [string]$typeProperty.Value
        $data = Get-ReviewerResponseProperty -Object $event -Name 'data'

        if ($eventType -ceq 'assistant.message_delta') { $deltaEvents++; continue }
        if ($eventType -ceq 'result') { $resultEvents++; continue }
        if ($eventType -like 'tool.*') { $toolEvents++; continue }
        if ($eventType -cne 'assistant.message') { continue }
        if ($null -eq $data) { continue }

        $ephemeral = Get-ReviewerResponseProperty -Object $data -Name 'ephemeral' -Default $false
        if ($ephemeral -is [bool] -and [bool]$ephemeral) { $ephemeralSkipped++; continue }

        $model = Get-ReviewerResponseProperty -Object $data -Name 'model' -Default $null
        if ($model -is [string] -and [string]$model -ne '') {
            if ($models -cnotcontains [string]$model) { [void]$models.Add([string]$model) }
        }
        $phase = Get-ReviewerResponseProperty -Object $data -Name 'phase' -Default $null
        if ($phase -is [string] -and [string]$phase -ne '') {
            if ($phases -cnotcontains [string]$phase) { [void]$phases.Add([string]$phase) }
        }
        $content = Get-ReviewerResponseProperty -Object $data -Name 'content' -Default $null
        if ($content -isnot [string]) { continue }
        if ([string]$content -eq '') { continue }
        if ($messages.Count -ge $MaxMessages) {
            if ($null -eq $truncatedAt) { $truncatedAt = $MaxMessages }
            continue
        }
        [void]$messages.Add([string]$content)
    }

    $canary = [pscustomobject][ordered]@{
        sawJsonLines            = ($jsonLines -gt 0)
        jsonLineCount           = [int]$jsonLines
        typedEventCount         = [int]$typedEvents
        unparsedJsonLineCount   = [int]$unparsedLines
        assistantMessageCount   = [int]$messages.Count
        ephemeralSkippedCount   = [int]$ephemeralSkipped
        deltaEventCount         = [int]$deltaEvents
        toolEventCount          = [int]$toolEvents
        resultEventCount        = [int]$resultEvents
        reportedModels          = [string[]]@($models.ToArray())
        reportedModelCount      = [int]$models.Count
        reportedPhases          = [string[]]@($phases.ToArray())
        phaseFieldPresent       = ($phases.Count -gt 0)
        messagesTruncatedAt     = $truncatedAt
    }
    return [pscustomobject][ordered]@{
        Messages = [string[]]@($messages.ToArray())
        Canary   = $canary
    }
}

function Test-ReviewerResponseEventShapeCanary {
    <#
        Decides whether a stream's SHAPE is one this parser understands.

        A stream is compatible when it either carried no JSON at all (an older
        CLI, or a run without --output-format: the narrow raw-stdout fallback
        handles that, with reduced authority) or carried recognizable typed
        events. A stream that is full of JSON lines none of which carry a `type`
        is a stream whose shape has changed underneath us, and guessing at it is
        exactly the failure mode the canary exists to refuse.

        More than one distinct reported model in one attempt is also refused: an
        attempt is an accounting unit bound to ONE authorized model, and a
        stream that reports two has either been concatenated from two runs or
        changed identity midway. Neither can be attributed honestly.
    #>
    param([Parameter(Mandatory)]$Canary)

    if ([bool]$Canary.sawJsonLines -and [int]$Canary.typedEventCount -eq 0) {
        return @{ Ok = $false; Detail = ("The CLI emitted $($Canary.jsonLineCount) JSON line(s) but no event carried a " +
                "'type' field; the event stream shape is not one this build can read.")
        }
    }
    if ([int]$Canary.reportedModelCount -gt 1) {
        return @{ Ok = $false; Detail = ("The CLI reported $($Canary.reportedModelCount) distinct models in one attempt " +
                "($([string[]]@($Canary.reportedModels) -join ', ')); an attempt binds exactly one model.")
        }
    }
    if ($null -ne $Canary.messagesTruncatedAt) {
        return @{ Ok = $false; Detail = ("The CLI emitted more than $($Canary.messagesTruncatedAt) assistant messages in " +
                'one attempt; the attempt exceeded the bounded transcript this build will read.')
        }
    }
    return @{ Ok = $true; Detail = '' }
}

# ---------------------------------------------------------------------------
# Occurrence scanning
# ---------------------------------------------------------------------------

function Get-ReviewerResponseNonceOccurrences {
    <#
        Every standalone nonce-challenge line in one text unit, in order.

        Standalone is the whole security property: the line must be nothing but
        the prefix, whitespace, and one whitespace-free token. A nonce mentioned
        mid-sentence, inside a fence, or trailed by prose is not a challenge
        response - and a hostile PR that persuades a model to quote text
        containing the prefix cannot manufacture one, because it does not know
        the value.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $pattern = '(?m)^[ \t]*' + [regex]::Escape($script:ReviewerResponseNoncePrefixV2) + '[ \t]*(\S+)[ \t]*\r?$'
    $values = [System.Collections.Generic.List[string]]::new()
    foreach ($match in [regex]::Matches([string]$Text, $pattern)) {
        [void]$values.Add([string]$match.Groups[1].Value)
    }
    return , [string[]]@($values.ToArray())
}

function Get-ReviewerResponsePayloadOccurrences {
    <#
        Every payload occurrence in one text unit, in order, as
        @{ Text; Bytes; Status }.

        The object is delimited by brace matching that respects JSON strings and
        escapes, bounded by a scan window, so a payload that never closes is
        reported as truncated rather than swallowing the rest of the transcript.
        Unlike v1 the payload may span lines: a model that pretty-prints its
        answer has still answered, and one-line-ness was never a security
        property - the nonce line is.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [int]$ScanWindowChars = $script:ReviewerResponseScanWindowCharsV2,
        [int]$MaxPayloadBytes = $script:ReviewerResponseMaxPayloadBytesV2,
        [int]$MaxOccurrences = $script:ReviewerResponseMaxOccurrencesV2
    )

    $occurrences = [System.Collections.Generic.List[object]]::new()
    $body = [string]$Text
    $anchorPattern = '(?m)^[ \t]*' + [regex]::Escape($script:ReviewerResponsePayloadPrefixV2)
    # Scanning is per anchor and each scan is window-bounded, so N anchors over
    # an L-character transcript is O(N*L) work on text the model controls. The
    # occurrence cap is therefore enforced HERE, as anchors are found, and not
    # after the whole unit has already been scanned: a cap that is checked once
    # the expensive part is over bounds the answer, not the work.
    $scanned = 0
    foreach ($anchor in [regex]::Matches($body, $anchorPattern)) {
        if ($occurrences.Count -gt $MaxOccurrences) { break }
        if ($scanned -ge $ScanWindowChars) {
            [void]$occurrences.Add(@{ Text = ''; Bytes = 0; Status = $script:ReviewerResponseReasonV2.PayloadOverflow })
            break
        }
        $searchStart = $anchor.Index + $anchor.Length
        if ($searchStart -ge $body.Length) {
            [void]$occurrences.Add(@{ Text = ''; Bytes = 0; Status = $script:ReviewerResponseReasonV2.TruncatedPayload })
            continue
        }
        $windowEnd = [Math]::Min($body.Length, $searchStart + ($ScanWindowChars - $scanned))
        $jsonStart = $body.IndexOf('{', $searchStart, $windowEnd - $searchStart)
        if ($jsonStart -lt 0) {
            $scanned += ($windowEnd - $searchStart)
            [void]$occurrences.Add(@{ Text = ''; Bytes = 0; Status = $script:ReviewerResponseReasonV2.MissingPayload })
            continue
        }
        $depth = 0
        $inString = $false
        $escaped = $false
        $jsonEnd = -1
        $windowLeft = $ScanWindowChars - $scanned
        $limit = [Math]::Min($body.Length, $jsonStart + $windowLeft)
        for ($i = $jsonStart; $i -lt $limit; $i++) {
            $ch = $body[$i]
            if ($inString) {
                if ($escaped) { $escaped = $false }
                elseif ($ch -eq '\') { $escaped = $true }
                elseif ($ch -eq '"') { $inString = $false }
                continue
            }
            if ($ch -eq '"') { $inString = $true; continue }
            if ($ch -eq '{') { $depth++; continue }
            if ($ch -eq '}') {
                $depth--
                if ($depth -eq 0) { $jsonEnd = $i; break }
            }
        }
        $scanned += ($limit - $jsonStart)
        if ($jsonEnd -lt 0) {
            # Why the object never closed decides whether retrying can help. If
            # the scan ran out of WINDOW the object is larger than this build
            # will ever accept, which is overflow and terminal. If it ran out of
            # TEXT the stream was cut short, which is truncation and retryable.
            $hitWindowLimit = (($limit - $jsonStart) -ge $windowLeft)
            $status = $script:ReviewerResponseReasonV2.TruncatedPayload
            if ($hitWindowLimit) { $status = $script:ReviewerResponseReasonV2.PayloadOverflow }
            [void]$occurrences.Add(@{ Text = ''; Bytes = ($limit - $jsonStart); Status = $status })
            continue
        }
        $raw = $body.Substring($jsonStart, $jsonEnd - $jsonStart + 1)
        $bytes = $script:ReviewerResponseUtf8.GetByteCount($raw)
        if ($bytes -gt $MaxPayloadBytes) {
            [void]$occurrences.Add(@{ Text = $raw; Bytes = $bytes; Status = $script:ReviewerResponseReasonV2.PayloadOverflow })
            continue
        }
        [void]$occurrences.Add(@{ Text = $raw; Bytes = $bytes; Status = $script:ReviewerResponseReasonV2.Ok })
    }
    return , [object[]]@($occurrences.ToArray())
}

# ---------------------------------------------------------------------------
# Extraction
# ---------------------------------------------------------------------------

function New-ReviewerResponseExtractionResult {
    <# One shape for every exit, so no caller has to branch on which fields
       happen to exist. #>
    param(
        [Parameter(Mandatory)][string]$ReasonCode,
        [Parameter(Mandatory)][string]$Classification,
        [Parameter(Mandatory)][bool]$Retryable,
        [Parameter(Mandatory)][string]$AuthTier,
        [Parameter(Mandatory)][string]$ExtractionSource,
        [Parameter(Mandatory)][string]$AuthorityClass,
        [AllowNull()]$EnvironmentClassification = $null,
        [AllowNull()]$Payload = $null,
        [AllowNull()]$PayloadText = $null,
        [AllowNull()][object[]]$Findings = $null,
        [AllowNull()]$SeverityCounts = $null,
        [AllowNull()]$NonceObserved = $null,
        [int]$NonceOccurrenceCount = 0,
        [int]$PayloadOccurrenceCount = 0,
        [AllowNull()]$EventShape = $null,
        [AllowNull()]$FinalAssistantText = $null,
        [AllowEmptyString()][string]$Field = '',
        [AllowEmptyString()][string]$Detail = ''
    )

    # Every optional field here is deliberately UNTYPED. A [string]-typed
    # parameter coerces $null to the empty string, which would turn "this
    # attempt emitted no nonce" into "this attempt emitted an empty nonce" - a
    # distinction the auth tiers are built on.
    $resolvedFindings = [object[]]@()
    if ($null -ne $Findings) { $resolvedFindings = [object[]]@($Findings) }
    $resolvedCounts = $SeverityCounts
    if ($null -eq $resolvedCounts) { $resolvedCounts = Get-ReviewerResponseSeverityCounts -Findings $resolvedFindings }
    $payloadSha = $null
    $payloadTextValue = $null
    if ($PayloadText -is [string]) {
        $payloadTextValue = [string]$PayloadText
        $payloadSha = Get-ReviewerResponseTextSha256 -Text $payloadTextValue
    }
    $environment = $null
    if ($EnvironmentClassification -is [string] -and [string]$EnvironmentClassification -ne '') {
        $environment = [string]$EnvironmentClassification
    }
    $observed = $null
    if ($NonceObserved -is [string] -and [string]$NonceObserved -ne '') { $observed = [string]$NonceObserved }
    $finalText = $null
    if ($FinalAssistantText -is [string]) { $finalText = [string]$FinalAssistantText }
    return [pscustomobject][ordered]@{
        Ok                        = ($ReasonCode -ceq $script:ReviewerResponseReasonV2.Ok)
        ReasonCode                = $ReasonCode
        Classification            = $Classification
        Retryable                 = [bool]$Retryable
        Terminal                  = (-not $Retryable -and $ReasonCode -cne $script:ReviewerResponseReasonV2.Ok)
        AuthTier                  = $AuthTier
        ExtractionSource          = $ExtractionSource
        AuthorityClass            = $AuthorityClass
        EnvironmentClassification = $environment
        Payload                   = $Payload
        PayloadText               = $payloadTextValue
        PayloadSha256             = $payloadSha
        Findings                  = $resolvedFindings
        SeverityCounts            = $resolvedCounts
        NonceObserved             = $observed
        NonceOccurrenceCount      = [int]$NonceOccurrenceCount
        PayloadOccurrenceCount    = [int]$PayloadOccurrenceCount
        EventShape                = $EventShape
        FinalAssistantText        = $finalText
        Field                     = [string]$Field
        Detail                    = [string]$Detail
    }
}

function Get-ReviewerModelResponseV2 {
    <#
        Extract and classify one attempt's v2 response from raw CLI stdout.

        ORDER OF AUTHORITY
          1. Ordered non-ephemeral assistant.message events. Every message is
             scanned, not just the last: a model that answers and then chats is
             common, and a model that answers twice identically has answered
             once. The LAST message carrying a payload wins when they agree,
             which is what "prefer last" means once agreement is already
             mandatory.
          2. Raw stdout, ONLY when there were no assistant events at all. That
             text is not attributable to the model - it is whatever the process
             printed - so it is recorded as `rawStdoutFallback` with reduced
             authority, classified as an environment condition, and can never
             reach the authenticated tier.

        AGREEMENT
          At least one payload occurrence is required. Every payload occurrence
          must be canonical-byte-identical and every nonce occurrence must be
          the same string; a conflicting pair of either is terminal, never
          retried, because a transcript that says two things about one attempt
          cannot be resolved by asking again.

        TIERS
          `authenticated` needs the exact nonce line, the exact bound source
          commit, a schema-valid payload and passing invariants.
          `evidenceOnly` is a payload that is valid and correctly bound but
          whose nonce is ABSENT - not wrong, not conflicting. A wrong or
          conflicting nonce is terminal and never downgrades to a tier.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$StdOutText,
        [Parameter(Mandatory)][string]$ExpectedNonce,
        [Parameter(Mandatory)][string]$ExpectedSourceCommit,
        [hashtable]$Schema,
        [int]$MaxFindingItems = $script:ReviewerResponseMaxFindingItemsV2,
        [int]$MaxOccurrences = $script:ReviewerResponseMaxOccurrencesV2,
        [int]$MaxPayloadBytes = $script:ReviewerResponseMaxPayloadBytesV2,
        [int]$ScanWindowChars = $script:ReviewerResponseScanWindowCharsV2
    )

    # The finding cap is a RUN parameter, not a module constant. The wrapper's
    # own -MaxFindings reaches 25, and a v2 extractor that always capped at its
    # default 12 would make a 13-finding answer that v1 accepts terminal under
    # v2 - a new way to lose a complete review, which is the opposite of why
    # this contract exists.
    if ($MaxFindingItems -lt 0 -or $MaxFindingItems -gt $script:ReviewerResponseMaxFindingCeilingV2) {
        throw ("The v2 extractor was asked for a finding bound of $MaxFindingItems; the hard ceiling is " +
            "$script:ReviewerResponseMaxFindingCeilingV2.")
    }
    if (-not $Schema) { $Schema = Get-ReviewerResponsePayloadSchemaV2 -MaxFindingItems $MaxFindingItems }
    if ($ExpectedNonce -notmatch '^[0-9a-f]{8,128}$') {
        throw "The v2 extractor was given a malformed expected nonce."
    }
    if ($ExpectedSourceCommit -notmatch '^[0-9a-fA-F]{40}$') {
        throw "The v2 extractor was given a malformed expected source commit."
    }
    $expectedCommit = $ExpectedSourceCommit.ToLowerInvariant()

    $events = Get-ReviewerResponseAssistantEvents -StdOutText $StdOutText
    $canary = $events.Canary
    $messages = [string[]]@($events.Messages)
    $shape = Test-ReviewerResponseEventShapeCanary -Canary $canary
    if (-not $shape.Ok) {
        return New-ReviewerResponseExtractionResult `
            -ReasonCode $script:ReviewerResponseReasonV2.EventShapeCanary -Classification 'environment' `
            -Retryable $true -AuthTier $script:ReviewerResponseAuthTierV2.None `
            -ExtractionSource 'assistantMessages' -AuthorityClass 'reduced' `
            -EnvironmentClassification 'eventShapeUnrecognized' -EventShape $canary `
            -Detail ([string]$shape.Detail)
    }

    $extractionSource = 'assistantMessages'
    $authorityClass = 'full'
    $environmentClassification = $null
    $units = [string[]]@($messages)
    $finalAssistantText = $null
    if ($messages.Count -gt 0) { $finalAssistantText = [string]$messages[$messages.Count - 1] }

    if ($messages.Count -eq 0) {
        # No assistant event carried content. The model may still have printed
        # its answer on a channel this build cannot attribute, so the raw text
        # is read once, at reduced authority, and the attempt is classified as
        # an environment condition either way.
        $extractionSource = 'rawStdoutFallback'
        $authorityClass = 'reduced'
        $environmentClassification = 'noAssistantEvents'
        $units = [string[]]@([string]$StdOutText)
    }

    $nonceValues = [System.Collections.Generic.List[string]]::new()
    $payloadTexts = [System.Collections.Generic.List[string]]::new()
    $payloadStatuses = [System.Collections.Generic.List[string]]::new()
    # Whether any single assistant message carried the challenge line AND the
    # payload, challenge first. Without this, a nonce echoed early in a reply
    # would authenticate a payload produced independently later in that same
    # reply, which is precisely the binding the challenge is supposed to make.
    $nonceBoundToPayload = $false
    foreach ($unit in $units) {
        $unitNonces = Get-ReviewerResponseNonceOccurrences -Text $unit
        foreach ($value in $unitNonces) {
            [void]$nonceValues.Add($value)
        }
        $unitPayloads = Get-ReviewerResponsePayloadOccurrences -Text $unit `
            -ScanWindowChars $ScanWindowChars -MaxPayloadBytes $MaxPayloadBytes -MaxOccurrences $MaxOccurrences
        $unitAcceptedPayloads = 0
        foreach ($occurrence in $unitPayloads) {
            [void]$payloadStatuses.Add([string]$occurrence.Status)
            if ([string]$occurrence.Status -ceq $script:ReviewerResponseReasonV2.Ok) {
                [void]$payloadTexts.Add([string]$occurrence.Text)
                $unitAcceptedPayloads++
            }
        }
        if ($unitAcceptedPayloads -gt 0 -and $unitNonces.Count -gt 0) {
            $nonceAt = $unit.IndexOf($script:ReviewerResponseNoncePrefixV2, [StringComparison]::Ordinal)
            $payloadAt = $unit.IndexOf($script:ReviewerResponsePayloadPrefixV2, [StringComparison]::Ordinal)
            if ($nonceAt -ge 0 -and $payloadAt -gt $nonceAt) { $nonceBoundToPayload = $true }
        }
    }

    $fail = {
        param([string]$ReasonCode, [bool]$Retryable, [string]$Classification, [string]$Detail, [string]$Field)
        return New-ReviewerResponseExtractionResult -ReasonCode $ReasonCode -Classification $Classification `
            -Retryable $Retryable -AuthTier $script:ReviewerResponseAuthTierV2.None `
            -ExtractionSource $extractionSource -AuthorityClass $authorityClass `
            -EnvironmentClassification $environmentClassification `
            -NonceOccurrenceCount $nonceValues.Count -PayloadOccurrenceCount $payloadTexts.Count `
            -EventShape $canary -FinalAssistantText $finalAssistantText -Field $Field -Detail $Detail
    }

    if ($nonceValues.Count -gt $MaxOccurrences -or $payloadStatuses.Count -gt $MaxOccurrences) {
        return (& $fail $script:ReviewerResponseReasonV2.PayloadOverflow $false 'terminal' `
            ("The attempt carried $($nonceValues.Count) nonce and $($payloadStatuses.Count) payload occurrence(s); " +
                "at most $MaxOccurrences of each are read.") '')
    }

    # A conflicting nonce pair is decided BEFORE the payload, because a
    # transcript that states two different credentials for one attempt is
    # unresolvable regardless of what the payload says.
    $observedNonce = $null
    if ($nonceValues.Count -gt 0) {
        $observedNonce = [string]$nonceValues[0]
        foreach ($value in $nonceValues) {
            if ([string]$value -cne $observedNonce) {
                return (& $fail $script:ReviewerResponseReasonV2.ConflictingNonce $false 'terminal' `
                    'Two nonce challenge lines in one attempt carried different values.' 'nonce')
            }
        }
        if ($observedNonce -cne $ExpectedNonce) {
            return (& $fail $script:ReviewerResponseReasonV2.WrongNonce $false 'terminal' `
                'A nonce challenge line carried a value this attempt did not issue.' 'nonce')
        }
    }

    if ($payloadTexts.Count -eq 0) {
        $overflowed = ($payloadStatuses -ccontains $script:ReviewerResponseReasonV2.PayloadOverflow)
        $truncated = ($payloadStatuses -ccontains $script:ReviewerResponseReasonV2.TruncatedPayload)
        if ($overflowed) {
            return (& $fail $script:ReviewerResponseReasonV2.PayloadOverflow $false 'terminal' `
                "A v2 payload exceeded the $MaxPayloadBytes-byte payload bound." 'payload')
        }
        if ($truncated) {
            return (& $fail $script:ReviewerResponseReasonV2.TruncatedPayload $true 'modelSlip' `
                "A v2 payload did not close inside the $ScanWindowChars-character scan window." 'payload')
        }
        if ($environmentClassification) {
            return (& $fail $script:ReviewerResponseReasonV2.NoAssistantEvents $true 'environment' `
                'The attempt produced no assistant message and no v2 payload on raw stdout.' '')
        }
        return (& $fail $script:ReviewerResponseReasonV2.MissingPayload $true 'modelSlip' `
            'No assistant message carried a v2 payload.' 'payload')
    }

    # An unreadable restatement is still a restatement. Dropping it because some
    # OTHER occurrence parsed would mean a transcript that says two things about
    # one attempt authenticates on the half that happens to be readable, which is
    # precisely the unresolvable case the agreement rule exists for.
    $unreadable = [object[]]@($payloadStatuses | Where-Object { $_ -cne $script:ReviewerResponseReasonV2.Ok })
    if ($unreadable.Count -gt 0) {
        return (& $fail $script:ReviewerResponseReasonV2.ConflictingPayload $false 'terminal' `
            ("One v2 payload occurrence parsed and $($unreadable.Count) other occurrence(s) did not " +
                "($($unreadable[0])); a transcript that states one attempt twice must state it identically.") 'payload')
    }

    # Agreement across occurrences, by canonical rendering rather than raw
    # bytes, so a compact copy and a pretty copy of ONE answer agree.
    $canonical = $null
    $parsedPayload = $null
    $chosenText = $null
    foreach ($text in $payloadTexts) {
        $parsed = $null
        try { $parsed = $text | ConvertFrom-Json -Depth 64 -ErrorAction Stop }
        catch {
            return (& $fail $script:ReviewerResponseReasonV2.MalformedPayload $true 'modelSlip' `
                'A v2 payload prefix was present but its object was not valid JSON.' 'payload')
        }
        if ($parsed -isnot [System.Management.Automation.PSCustomObject]) {
            return (& $fail $script:ReviewerResponseReasonV2.NonObjectPayload $true 'modelSlip' `
                'A v2 payload was not a JSON object.' 'payload')
        }
        $rendered = ConvertTo-ReviewerResponseCanonicalJson -Value $parsed
        if ($null -eq $canonical) {
            $canonical = $rendered
            $parsedPayload = $parsed
            $chosenText = $rendered
            continue
        }
        if ($rendered -cne $canonical) {
            return (& $fail $script:ReviewerResponseReasonV2.ConflictingPayload $false 'terminal' `
                'Two v2 payload occurrences in one attempt disagreed.' 'payload')
        }
        # Identical: prefer the LAST agreeing occurrence as the representative.
        $parsedPayload = $parsed
        $chosenText = $rendered
    }

    $validated = Test-ReviewerResponsePayloadV2 -Parsed $parsedPayload -Schema $Schema
    if (-not $validated.Ok) {
        # An overflow of a NAMED field or item is a model writing too much in one
        # place - the same emission slip v1 classifies as retryable, and exactly
        # what a fresh attempt with a fresh nonce can fix. An overflow with no
        # field is transport-level: the payload itself is larger than this build
        # will ever read, and no retry changes that.
        $overflow = ([string]$validated.Reason -ceq $script:ReviewerResponseReasonV2.PayloadOverflow)
        $retryable = (-not $overflow) -or ([string]$validated.Field -ne '')
        $classification = if ($retryable) { 'modelSlip' } else { 'terminal' }
        return (& $fail ([string]$validated.Reason) $retryable $classification ([string]$validated.Detail) ([string]$validated.Field))
    }
    $payload = $validated.Payload
    $findings = [object[]]@($validated.Findings)

    if ([string]$payload.reviewedSourceCommit -cne $expectedCommit) {
        return (& $fail $script:ReviewerResponseReasonV2.WrongSourceCommit $false 'terminal' `
            'The v2 payload claimed a source commit this attempt was not bound to.' 'reviewedSourceCommit')
    }

    $vote = Test-ReviewerResponseVoteInvariant -RecommendedVote ([string]$payload.recommendedVote) -Findings $findings
    if (-not $vote.Ok) {
        return (& $fail ([string]$vote.Reason) $false 'terminal' ([string]$vote.Detail) 'recommendedVote')
    }

    # The tier. `authenticated` requires the challenge AND full authority: a raw
    # stdout fallback is never attributable enough to vote on, however
    # well-formed its payload.
    $tier = $script:ReviewerResponseAuthTierV2.EvidenceOnly
    $detail = 'The payload is valid and correctly bound but the attempt emitted no nonce challenge line.'
    if ($nonceValues.Count -gt 0 -and $authorityClass -ceq 'full' -and $nonceBoundToPayload) {
        $tier = $script:ReviewerResponseAuthTierV2.Authenticated
        $detail = ''
    }
    elseif ($nonceValues.Count -gt 0 -and $authorityClass -ceq 'full') {
        $detail = ('The nonce challenge and the payload never appeared together in one assistant message, ' +
            'challenge first, so the challenge is not bound to this answer.')
    }
    elseif ($nonceValues.Count -gt 0) {
        $detail = 'The nonce challenge was present but arrived on raw stdout, which this build cannot attribute to the model.'
    }

    return New-ReviewerResponseExtractionResult -ReasonCode $script:ReviewerResponseReasonV2.Ok `
        -Classification 'accepted' -Retryable $false -AuthTier $tier `
        -ExtractionSource $extractionSource -AuthorityClass $authorityClass `
        -EnvironmentClassification $environmentClassification `
        -Payload $payload -PayloadText $chosenText -Findings $findings `
        -SeverityCounts ($vote.SeverityCounts) -NonceObserved $observedNonce `
        -NonceOccurrenceCount $nonceValues.Count -PayloadOccurrenceCount $payloadTexts.Count `
        -EventShape $canary -FinalAssistantText $finalAssistantText -Detail $detail
}

function Test-ReviewerResponseNoNonceReinjection {
    <#
        A structural assertion, run by the test suite and by the envelope
        builder: nothing on the extraction path ever writes the expected nonce
        into a model-derived object.

        The payload's closed key set already forbids a `nonce` key, and
        `nonceObserved` is copied from the transcript. This states that
        explicitly so a future edit that "helpfully" fills the nonce in to make
        a payload validate fails a test rather than silently restoring the exact
        credential-forging hazard v2 removes.
    #>
    param(
        [Parameter(Mandatory)]$Extraction,
        [Parameter(Mandatory)][string]$ExpectedNonce
    )

    if ($null -ne $Extraction.Payload) {
        if ($Extraction.Payload.PSObject.Properties['nonce']) {
            return @{ Ok = $false; Detail = 'The validated payload carried a nonce key; the v2 payload object is closed.' }
        }
        $rendered = ConvertTo-ReviewerResponseCanonicalJson -Value $Extraction.Payload
        if ($rendered.Contains($ExpectedNonce)) {
            return @{ Ok = $false; Detail = 'The validated payload contained the expected nonce; the parser must never reinject it.' }
        }
    }
    if ($Extraction.NonceOccurrenceCount -eq 0 -and $null -ne $Extraction.NonceObserved) {
        return @{ Ok = $false; Detail = 'An attempt with no nonce occurrence reported an observed nonce.' }
    }
    return @{ Ok = $true; Detail = '' }
}

# ---------------------------------------------------------------------------
# Run-key path startup self-check
# ---------------------------------------------------------------------------

function Get-ReviewerResponseRunKeyFallbackRoot {
    <#
        Where a v2 run key goes when the agent's state directory sits inside a
        root the reviewed material can read.

        This is a per-user location, never a temp directory: a key regenerated
        every run would make cross-run substitution undetectable, because every
        envelope would verify under whatever key happened to exist when it was
        checked. Stability is the property that makes the seal worth taking.
    #>
    param()

    $local = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    if ([string]::IsNullOrWhiteSpace($local)) {
        $local = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
    }
    if ([string]::IsNullOrWhiteSpace($local)) {
        throw 'No per-user root is available to hold a v2 response run key outside the readable roots.'
    }
    return (Join-Path (Join-Path (Join-Path $local 'devpilot') 'reviewer') 'run-keys')
}

function Assert-ReviewerResponseRunKeyPath {
    <#
        Refuses a run key that lives anywhere the material it authenticates can
        reach.

        A seal is only evidence if the thing being sealed cannot obtain the key.
        A key under the repository would ship in a clone; a key under the tree
        the envelopes are WRITTEN to would sit beside the artifacts it signs, so
        whoever can rewrite an artifact could re-sign it; a key under any root
        the model can read is a key the model can sign with. Each of those turns
        the envelope from evidence into a self-describing document, which is
        precisely the tautology the seal exists to escape.

        ArtifactRoot is the artifact/output tree, not the agent's private state
        directory. The distinction matters: the run key deliberately lives in
        that private directory alongside the existing per-user signing key, and
        what must be excluded is the subtree that sealed artifacts land in.

        The check is a STARTUP check on purpose: discovering it at signing time
        means a run already happened under a key that proves nothing.
    #>
    param(
        [Parameter(Mandatory)][string]$KeyPath,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$ArtifactRoot,
        [AllowNull()][string[]]$ModelReadableRoots = $null
    )

    if ([string]::IsNullOrWhiteSpace($KeyPath)) { throw "The run key path is empty." }
    if (-not [IO.Path]::IsPathRooted($KeyPath)) {
        throw "The run key path '$KeyPath' is not absolute; a relative key path resolves differently per process."
    }
    $full = [IO.Path]::GetFullPath($KeyPath)
    $parent = [IO.Path]::GetDirectoryName($full)
    if ([string]::IsNullOrWhiteSpace($parent)) {
        throw "The run key path '$KeyPath' has no parent directory."
    }
    $within = {
        param([string]$Candidate, [string]$Root)
        if ([string]::IsNullOrWhiteSpace($Root)) { return $false }
        $rootFull = [IO.Path]::GetFullPath($Root)
        $rootPrefix = $rootFull.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) +
            [IO.Path]::DirectorySeparatorChar
        if ($Candidate.Equals($rootFull, [StringComparison]::OrdinalIgnoreCase)) { return $true }
        return $Candidate.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)
    }
    $forbidden = [System.Collections.Generic.List[object]]::new()
    [void]$forbidden.Add(@{ Label = 'the repository'; Root = $RepoRoot })
    [void]$forbidden.Add(@{ Label = 'the sealed-artifact output tree'; Root = $ArtifactRoot })
    foreach ($root in [string[]]@($ModelReadableRoots)) {
        if ([string]::IsNullOrWhiteSpace($root)) { continue }
        [void]$forbidden.Add(@{ Label = "a model-readable root ('$root')"; Root = $root })
    }
    foreach ($entry in $forbidden) {
        if (& $within $full ([string]$entry.Root)) {
            throw ("The run key '$full' resolves inside $($entry.Label); a key the sealed material can read " +
                'authenticates nothing.')
        }
    }
    if (Test-Path -LiteralPath $full) {
        $item = Get-Item -LiteralPath $full -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "The run key '$full' is a reparse point; its bytes can change without the path changing."
        }
    }
    return [pscustomobject][ordered]@{
        keyPath   = $full
        parent    = $parent
        exists    = [bool](Test-Path -LiteralPath $full -PathType Leaf)
        checkedAt = [DateTime]::UtcNow.ToString('o')
    }
}

function Get-ReviewerResponseSealSubkey {
    <#
        Domain separation. The run key is never used directly: every seal in
        this envelope family is taken under a subkey derived for exactly one
        domain, so an envelope signature can never be replayed as, or confused
        with, any other artifact this toolkit signs under the same run key.
    #>
    param(
        [Parameter(Mandatory)][byte[]]$RunKey,
        [Parameter(Mandatory)][string]$Domain
    )

    if ($RunKey.Length -lt 32) { throw "The run key must carry at least 32 bytes; it carries $($RunKey.Length)." }
    $hmac = [Security.Cryptography.HMACSHA256]::new($RunKey)
    try { return , $hmac.ComputeHash($script:ReviewerResponseUtf8.GetBytes($Domain)) }
    finally { $hmac.Dispose() }
}

function Get-ReviewerResponseKeyId {
    <# A stable, non-secret identifier for the run key, so two envelopes can be
       compared for "same key" without either revealing it. #>
    param([Parameter(Mandatory)][byte[]]$RunKey)

    $subkey = Get-ReviewerResponseSealSubkey -RunKey $RunKey `
        -Domain 'devpilot.reviewer.result-envelope.v2.keyid'
    return [Convert]::ToHexString([byte[]]$subkey).ToLowerInvariant().Substring(0, 16)
}

# ---------------------------------------------------------------------------
# The wrapper envelope
# ---------------------------------------------------------------------------

function New-ReviewerModelResponseEnvelopeV2 {
    <#
        Builds the wrapper-owned `reviewer-result-envelope.v2` document.

        Every binding here is the WRAPPER's own state. The model contributes
        exactly one thing - the validated payload - and one claim about its own
        identity, which is recorded next to the requested model and classified,
        never substituted for it.
    #>
    param(
        [Parameter(Mandatory)]$Extraction,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$AttemptId,
        [Parameter(Mandatory)][int]$AttemptIndex,
        [Parameter(Mandatory)][string]$Nonce,
        [Parameter(Mandatory)][hashtable]$Binding,
        [Parameter(Mandatory)][hashtable]$Model,
        [Parameter(Mandatory)][hashtable]$Hashes,
        [hashtable]$Process = @{},
        [hashtable]$Timings = @{},
        [hashtable]$Session = @{},
        [int]$MaxFindingItems = $script:ReviewerResponseMaxFindingItemsV2
    )

    $guard = Test-ReviewerResponseNoNonceReinjection -Extraction $Extraction -ExpectedNonce $Nonce
    if (-not $guard.Ok) { throw "Refusing to seal a v2 envelope: $($guard.Detail)" }

    $required = [string[]]@('project', 'repositoryId', 'repositoryName', 'organization', 'prId',
        'sourceCommit', 'sourceBranch', 'targetBranch', 'changeSetDigest')
    foreach ($name in $required) {
        if (-not $Binding.ContainsKey($name)) { throw "The v2 envelope binding is missing '$name'." }
    }
    foreach ($name in [string[]]@('requested', 'reported')) {
        if (-not $Model.ContainsKey($name)) { throw "The v2 envelope model record is missing '$name'." }
    }
    $requestedModel = [string]$Model['requested']
    $reportedModel = $Model['reported']
    $reportedModelText = $null
    $claimStatus = 'unreported'
    if ($reportedModel -is [string] -and [string]$reportedModel -ne '') {
        $reportedModelText = [string]$reportedModel
        if ($reportedModelText -ceq $requestedModel) { $claimStatus = 'match' } else { $claimStatus = 'mismatch' }
    }

    $tier = [string]$Extraction.AuthTier
    $mayVote = ($tier -ceq $script:ReviewerResponseAuthTierV2.Authenticated)
    $findings = [object[]]@($Extraction.Findings)
    $counts = Get-ReviewerResponseSeverityCounts -Findings $findings
    $recommendedVote = ''
    if ($null -ne $Extraction.Payload) { $recommendedVote = [string]$Extraction.Payload.recommendedVote }
    $voteCheck = Test-ReviewerResponseVoteInvariant -RecommendedVote $recommendedVote -Findings $findings
    $commitBound = $false
    $payloadClosed = $true
    if ($null -ne $Extraction.Payload) {
        $commitBound = ([string]$Extraction.Payload.reviewedSourceCommit -ceq
            ([string]$Binding['sourceCommit']).ToLowerInvariant())
        $unexpectedKeys = [string[]]@([string[]]@($Extraction.Payload.PSObject.Properties.Name) |
                Where-Object { $script:ReviewerResponsePayloadKeysV2 -cnotcontains $_ })
        $payloadClosed = ($unexpectedKeys.Count -eq 0)
    }

    $hashOrNull = {
        param([string]$Name)
        if (-not $Hashes.ContainsKey($Name)) { return $null }
        $value = $Hashes[$Name]
        if ($null -eq $value) { return $null }
        $text = [string]$value
        if ($text -notmatch '^[0-9a-f]{64}$') { throw "The v2 envelope hash '$Name' is not a lowercase sha256 hex digest." }
        return $text
    }
    $processValue = {
        param([string]$Name, $Default)
        if ($Process.ContainsKey($Name)) { return $Process[$Name] }
        return $Default
    }
    $timingValue = {
        param([string]$Name, $Default)
        if ($Timings.ContainsKey($Name)) { return $Timings[$Name] }
        return $Default
    }
    $sessionValue = {
        param([string]$Name, $Default)
        if ($Session.ContainsKey($Name)) { return $Session[$Name] }
        return $Default
    }

    $envelope = [ordered]@{
        kind          = $script:ReviewerResponseEnvelopeKindV2
        schemaVersion = $script:ReviewerResponseEnvelopeSchemaVersionV2
        run           = [pscustomobject][ordered]@{
            runId        = [string]$RunId
            attemptId    = [string]$AttemptId
            attemptIndex = [int]$AttemptIndex
            sessionId    = (& $sessionValue 'sessionId' $null)
            processId    = (& $sessionValue 'processId' $null)
            host         = (& $sessionValue 'host' $null)
            runKeyOrigin = [string](& $sessionValue 'runKeyOrigin' 'stateDirectory')
        }
        nonce         = [string]$Nonce
        binding       = [pscustomobject][ordered]@{
            organization    = [string]$Binding['organization']
            project         = [string]$Binding['project']
            repositoryId    = [string]$Binding['repositoryId']
            repositoryName  = [string]$Binding['repositoryName']
            prId            = [int]$Binding['prId']
            sourceCommit    = ([string]$Binding['sourceCommit']).ToLowerInvariant()
            sourceBranch    = [string]$Binding['sourceBranch']
            targetBranch    = [string]$Binding['targetBranch']
            changeSetDigest = [string]$Binding['changeSetDigest']
        }
        model         = [pscustomobject][ordered]@{
            requested   = $requestedModel
            reported    = $reportedModelText
            claimStatus = $claimStatus
        }
        inputs        = [pscustomobject][ordered]@{
            promptSha256   = (& $hashOrNull 'prompt')
            inputSha256    = (& $hashOrNull 'input')
            configSha256   = (& $hashOrNull 'config')
            scriptSha256   = (& $hashOrNull 'script')
            snapshotSha256 = (& $hashOrNull 'snapshot')
        }
        outputs       = [pscustomobject][ordered]@{
            finalAssistantSha256 = (& $hashOrNull 'finalAssistant')
            rawStdOutSha256      = (& $hashOrNull 'rawStdOut')
            stdErrSha256         = (& $hashOrNull 'stdErr')
            payloadSha256        = $Extraction.PayloadSha256
        }
        extraction    = [pscustomobject][ordered]@{
            source                    = [string]$Extraction.ExtractionSource
            authorityClass            = [string]$Extraction.AuthorityClass
            environmentClassification = $Extraction.EnvironmentClassification
            reasonCode                = [string]$Extraction.ReasonCode
            classification            = [string]$Extraction.Classification
            retryable                 = [bool]$Extraction.Retryable
            nonceOccurrenceCount      = [int]$Extraction.NonceOccurrenceCount
            payloadOccurrenceCount    = [int]$Extraction.PayloadOccurrenceCount
            nonceObserved             = ($null -ne $Extraction.NonceObserved)
            eventShape                = $Extraction.EventShape
        }
        payload       = $Extraction.Payload
        derived       = [pscustomobject][ordered]@{
            findingCount    = [int]$findings.Count
            severityCounts  = $counts
            recommendedVote = $recommendedVote
            invariants      = [pscustomobject][ordered]@{
                voteConsistent      = [bool]$voteCheck.Ok
                commitBound         = [bool]$commitBound
                findingsWithinCap   = ([int]$findings.Count -le $MaxFindingItems)
                payloadClosed       = [bool]$payloadClosed
                nonceNotReinjected  = $true
            }
        }
        authTier      = $tier
        capabilities  = [pscustomobject][ordered]@{
            mayVote          = $mayVote
            mayMarkReviewed  = $mayVote
            mayBecomeEligible = $mayVote
            mayReconcile     = $mayVote
            mayDeliver       = $mayVote
            mayCountInCensus = ($tier -cne $script:ReviewerResponseAuthTierV2.None)
        }
        process       = [pscustomobject][ordered]@{
            exitCode    = (& $processValue 'exitCode' $null)
            timedOut    = [bool](& $processValue 'timedOut' $false)
            stdOutBytes = [int](& $processValue 'stdOutBytes' 0)
            stdErrBytes = [int](& $processValue 'stdErrBytes' 0)
        }
        timings       = [pscustomobject][ordered]@{
            startedAtUtc   = (& $timingValue 'startedAtUtc' $null)
            completedAtUtc = (& $timingValue 'completedAtUtc' $null)
            durationMs     = (& $timingValue 'durationMs' $null)
        }
    }
    return [pscustomobject]$envelope
}

function Get-ReviewerResponseEnvelopeInventory {
    <#
        The inventory the seal covers: one record per named byte artifact this
        envelope claims to describe, in ordinal name order.

        The signature already covers the envelope's own canonical text, so the
        inventory is not a second integrity mechanism for the same bytes. It is
        the list of EXTERNAL artifacts - prompt, input, config, script,
        snapshot, transcript, payload - whose digests the envelope asserts, made
        explicit so a later verification can enumerate exactly what was claimed
        rather than rediscovering it from field names.
    #>
    param([Parameter(Mandatory)]$Envelope)

    $records = [System.Collections.Generic.List[object]]::new()
    $add = {
        param([string]$Name, $Digest)
        if ($null -eq $Digest) { return }
        $text = [string]$Digest
        if ($text -eq '') { return }
        [void]$records.Add([pscustomobject][ordered]@{ name = $Name; sha256 = $text })
    }
    # Only the named digest artifacts belong here. Enumerating a section
    # generically would also pick up a dictionary's own Keys/Count members if a
    # section were ever built as a hashtable, silently filling the inventory
    # with type internals instead of digests.
    $inputNames = [string[]]@('promptSha256', 'inputSha256', 'configSha256', 'scriptSha256', 'snapshotSha256')
    foreach ($name in $inputNames) {
        & $add ('inputs.' + $name) (Get-ReviewerResponseProperty -Object $Envelope.inputs -Name $name -Default $null)
    }
    $outputNames = [string[]]@('finalAssistantSha256', 'rawStdOutSha256', 'stdErrSha256', 'payloadSha256')
    foreach ($name in $outputNames) {
        & $add ('outputs.' + $name) (Get-ReviewerResponseProperty -Object $Envelope.outputs -Name $name -Default $null)
    }
    $sorted = [object[]]@($records.ToArray() | Sort-Object -Property @{ Expression = { [string]$_.name } } -CaseSensitive)
    return , $sorted
}

function Protect-ReviewerModelResponseEnvelope {
    <#
        Seals an envelope: attaches the inventory, then signs the canonical text
        of everything except the signature itself under a domain-separated
        subkey of the run key.

        Cross-run substitution is defeated by the sealed bytes, not by a
        separate check: runId, attemptId, attemptIndex, the nonce and the full
        binding are all inside the signed text, so an envelope lifted from
        another run verifies only against the run it was actually made for.
    #>
    param(
        [Parameter(Mandatory)]$Envelope,
        [Parameter(Mandatory)][byte[]]$RunKey,
        [string]$Domain = 'devpilot.reviewer.result-envelope.v2'
    )

    if ([string]$Envelope.kind -cne $script:ReviewerResponseEnvelopeKindV2) {
        throw "Refusing to seal a document of kind '$($Envelope.kind)' as a v2 result envelope."
    }
    $inventory = Get-ReviewerResponseEnvelopeInventory -Envelope $Envelope
    $ordered = [ordered]@{}
    foreach ($property in $Envelope.PSObject.Properties) {
        if ($property.Name -ceq 'seal') { continue }
        $ordered[$property.Name] = $property.Value
    }
    $ordered['seal'] = [pscustomobject][ordered]@{
        algorithm = 'HMACSHA256'
        domain    = $Domain
        keyId     = Get-ReviewerResponseKeyId -RunKey $RunKey
        inventory = $inventory
        signature = ''
    }
    $sealed = [pscustomobject]$ordered
    $signature = Get-ReviewerResponseEnvelopeSignature -Envelope $sealed -RunKey $RunKey -Domain $Domain
    $sealed.seal.signature = $signature
    return $sealed
}

function Get-ReviewerResponseEnvelopeSignature {
    <# The signature over the canonical text of the envelope with an empty
       signature field, so signing and verifying hash exactly the same bytes. #>
    param(
        [Parameter(Mandatory)]$Envelope,
        [Parameter(Mandatory)][byte[]]$RunKey,
        [Parameter(Mandatory)][string]$Domain
    )

    $ordered = [ordered]@{}
    foreach ($property in $Envelope.PSObject.Properties) {
        if ($property.Name -ceq 'seal') { continue }
        $ordered[$property.Name] = $property.Value
    }
    $seal = [ordered]@{}
    foreach ($property in $Envelope.seal.PSObject.Properties) {
        if ($property.Name -ceq 'signature') { $seal[$property.Name] = ''; continue }
        $seal[$property.Name] = $property.Value
    }
    $ordered['seal'] = [pscustomobject]$seal
    $canonical = ConvertTo-ReviewerResponseCanonicalJson -Value ([pscustomobject]$ordered)
    $subkey = Get-ReviewerResponseSealSubkey -RunKey $RunKey -Domain $Domain
    $hmac = [Security.Cryptography.HMACSHA256]::new([byte[]]$subkey)
    try {
        return [Convert]::ToHexString($hmac.ComputeHash($script:ReviewerResponseUtf8.GetBytes($canonical))).ToLowerInvariant()
    }
    finally { $hmac.Dispose() }
}

function Test-ReviewerModelResponseEnvelopeSeal {
    <# Constant-time signature comparison, so a wrong signature cannot be
       recovered a byte at a time by repeated verification attempts. #>
    param(
        [Parameter(Mandatory)]$Envelope,
        [Parameter(Mandatory)][byte[]]$RunKey
    )

    $sealProperty = $Envelope.PSObject.Properties['seal']
    if (-not $sealProperty -or $null -eq $sealProperty.Value) { return $false }
    $seal = $sealProperty.Value
    if ([string](Get-ReviewerResponseProperty -Object $seal -Name 'algorithm' -Default '') -cne 'HMACSHA256') { return $false }
    $domain = [string](Get-ReviewerResponseProperty -Object $seal -Name 'domain' -Default '')
    if ([string]::IsNullOrWhiteSpace($domain)) { return $false }
    $keyId = [string](Get-ReviewerResponseProperty -Object $seal -Name 'keyId' -Default '')
    if ($keyId -cne (Get-ReviewerResponseKeyId -RunKey $RunKey)) { return $false }
    $claimed = [string](Get-ReviewerResponseProperty -Object $seal -Name 'signature' -Default '')
    if ($claimed -notmatch '^[0-9a-f]{64}$') { return $false }
    $expected = Get-ReviewerResponseEnvelopeSignature -Envelope $Envelope -RunKey $RunKey -Domain $domain
    return [Security.Cryptography.CryptographicOperations]::FixedTimeEquals(
        $script:ReviewerResponseUtf8.GetBytes($claimed), $script:ReviewerResponseUtf8.GetBytes($expected))
}

# ---------------------------------------------------------------------------
# Strict version dispatch and verified downstream consumption
# ---------------------------------------------------------------------------

function Read-ReviewerModelResponseEnvelope {
    <#
        Strict version dispatch.

        v2 documents are read here. A v1 document is RECOGNIZED and refused with
        a message that says so, rather than being coerced: v1 artifacts belong
        to the v1 reader, and silently upgrading one would invent bindings the
        v1 document never carried. An unknown kind or version is refused
        outright.
    #>
    param(
        [Parameter(Mandatory)]$Envelope,
        [Parameter(Mandatory)][byte[]]$RunKey,
        [AllowNull()]$ExpectedRunId = $null,
        [AllowNull()]$ExpectedAttemptId = $null,
        [AllowNull()]$ExpectedNonce = $null,
        [AllowNull()]$ExpectedPrId = $null,
        [AllowNull()]$ExpectedSourceCommit = $null,
        [switch]$AllowUnsealed
    )

    $kind = [string](Get-ReviewerResponseProperty -Object $Envelope -Name 'kind' -Default '')
    $version = Get-ReviewerResponseProperty -Object $Envelope -Name 'schemaVersion' -Default $null
    if ($kind -ceq $script:ReviewerResponseEnvelopeKindV1) {
        throw ("This is a '$kind' document. Version dispatch is strict: v1 artifacts are read only by the v1 reader " +
            'and are never upgraded in place.')
    }
    if ($kind -cne $script:ReviewerResponseEnvelopeKindV2) {
        throw "Unknown result-envelope kind '$kind'; expected '$script:ReviewerResponseEnvelopeKindV2'."
    }
    if (-not (Test-ReviewerResponseStrictInt -Value $version -Min $script:ReviewerResponseEnvelopeSchemaVersionV2 `
                -Max $script:ReviewerResponseEnvelopeSchemaVersionV2)) {
        throw ("A '$kind' document declared schemaVersion '$version'; this build reads only " +
            "$script:ReviewerResponseEnvelopeSchemaVersionV2.")
    }
    if (-not $AllowUnsealed) {
        if (-not (Test-ReviewerModelResponseEnvelopeSeal -Envelope $Envelope -RunKey $RunKey)) {
            throw 'The v2 result envelope failed its seal; downstream consumes verified envelopes only.'
        }
    }

    # A valid seal proves the bytes were written by something holding the run
    # key. It does NOT prove they describe the attempt in front of us: the key
    # outlives a run, so a whole intact envelope from an earlier run, attempt,
    # pull request, or commit verifies perfectly. The caller therefore states
    # what it expects, and a mismatch is a refusal rather than a silent
    # substitution.
    $expectations = [ordered]@{
        'run.runId'           = @($ExpectedRunId, [string]$Envelope.run.runId)
        'run.attemptId'       = @($ExpectedAttemptId, [string]$Envelope.run.attemptId)
        'nonce'               = @($ExpectedNonce, [string]$Envelope.nonce)
        'binding.prId'        = @($ExpectedPrId, [string]$Envelope.binding.prId)
        'binding.sourceCommit' = @($ExpectedSourceCommit, [string]$Envelope.binding.sourceCommit)
    }
    foreach ($name in [string[]]@($expectations.Keys)) {
        $expected = $expectations[$name][0]
        if ($null -eq $expected) { continue }
        if ([string]$expected -cne [string]$expectations[$name][1]) {
            throw ("A v2 result envelope was presented for $name '$expected' but describes " +
                "'$($expectations[$name][1])'. A sealed envelope from another attempt is not this attempt.")
        }
    }

    # Capabilities are rederived from the tier rather than believed. The stored
    # booleans are sealed, so a mismatch means the writer and this reader
    # disagree about what a tier permits - which is exactly the drift that would
    # let a future edit hand `evidenceOnly` a vote.
    $tier = [string](Get-ReviewerResponseProperty -Object $Envelope -Name 'authTier' -Default '')
    $eligible = Test-ReviewerModelResponseEligible -AuthTier $tier
    $capabilities = $Envelope.capabilities
    foreach ($name in [string[]]@('mayVote', 'mayMarkReviewed', 'mayBecomeEligible', 'mayReconcile', 'mayDeliver')) {
        if ([bool](Get-ReviewerResponseProperty -Object $capabilities -Name $name -Default $false) -ne $eligible) {
            throw "A v2 result envelope claims '$name' inconsistent with auth tier '$tier'."
        }
    }
    if ([bool](Get-ReviewerResponseProperty -Object $capabilities -Name 'mayCountInCensus' -Default $false) -ne
        ($tier -cne $script:ReviewerResponseAuthTierV2.None)) {
        throw "A v2 result envelope claims a census capability inconsistent with auth tier '$tier'."
    }
    return $Envelope
}

function Get-ReviewerVerifiedModelResponse {
    <#
        The single downstream entry point.

        Nothing below this line reads a payload that has not been through here,
        which is what makes "downstream consumes the verified envelope only" a
        code path rather than a convention. The returned record states the tier
        and the capabilities it implies, so a caller cannot accidentally treat
        evidence as a vote.
    #>
    param(
        [Parameter(Mandatory)]$Envelope,
        [Parameter(Mandatory)][byte[]]$RunKey
    )

    $verified = Read-ReviewerModelResponseEnvelope -Envelope $Envelope -RunKey $RunKey
    $tier = [string]$verified.authTier
    $findings = [object[]]@()
    if ($null -ne $verified.payload) { $findings = [object[]]@($verified.payload.findings) }
    return [pscustomobject][ordered]@{
        Verified        = $true
        AuthTier        = $tier
        Payload         = $verified.payload
        Findings        = $findings
        SeverityCounts  = $verified.derived.severityCounts
        RecommendedVote = [string]$verified.derived.recommendedVote
        MayVote         = [bool]$verified.capabilities.mayVote
        MayDeliver      = [bool]$verified.capabilities.mayDeliver
        MayReconcile    = [bool]$verified.capabilities.mayReconcile
        CountsInCensus  = [bool]$verified.capabilities.mayCountInCensus
        Binding         = $verified.binding
        Run             = $verified.run
    }
}

function Test-ReviewerModelResponseEligible {
    <#
        The slot/verifier/delivery gate. Only `authenticated` is eligible.

        `evidenceOnly` returns false here and NOTHING about that is "unknown":
        the census entry is complete, the payload is sealed, and the reason is
        recorded. That distinction is the whole design - a pass whose model
        forgot the challenge line is a pass that produced evidence and no vote,
        not a pass that vanished.
    #>
    param([Parameter(Mandatory)][string]$AuthTier)

    return ($AuthTier -ceq $script:ReviewerResponseAuthTierV2.Authenticated)
}

function Get-ReviewerModelResponseCensusRecord {
    <#
        The census projection of one attempt. It is COMPLETE for every tier,
        including `evidenceOnly` and including a terminal rejection, because an
        attempt that is missing from the census is the failure this whole change
        exists to remove.
    #>
    param(
        [Parameter(Mandatory)]$Envelope,
        [Parameter(Mandatory)][byte[]]$RunKey
    )

    $verified = Read-ReviewerModelResponseEnvelope -Envelope $Envelope -RunKey $RunKey
    return [pscustomobject][ordered]@{
        runId          = [string]$verified.run.runId
        attemptId      = [string]$verified.run.attemptId
        attemptIndex   = [int]$verified.run.attemptIndex
        prId           = [int]$verified.binding.prId
        sourceCommit   = [string]$verified.binding.sourceCommit
        requestedModel = [string]$verified.model.requested
        modelClaim     = [string]$verified.model.claimStatus
        authTier       = [string]$verified.authTier
        reasonCode     = [string]$verified.extraction.reasonCode
        extractionSource = [string]$verified.extraction.source
        findingCount   = [int]$verified.derived.findingCount
        recommendedVote = [string]$verified.derived.recommendedVote
        counted        = [bool]$verified.capabilities.mayCountInCensus
        eligible       = (Test-ReviewerModelResponseEligible -AuthTier ([string]$verified.authTier))
        sealed         = $true
    }
}

# ---------------------------------------------------------------------------
# Prompt-side contract text
# ---------------------------------------------------------------------------

function Get-ReviewerResponseContractTextV2 {
    <#
        The exact contract lines injected into the runtime context.

        The nonce is issued here as a whole line the model copies, not as a
        field buried at the end of a several-kilobyte object - which is the
        single change that makes the credential survivable to emit.
    #>
    param(
        [Parameter(Mandatory)][string]$Nonce,
        [Parameter(Mandatory)][string]$SourceCommit,
        [int]$MaxFindings = $script:ReviewerResponseMaxFindingItemsV2
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    [void]$lines.Add('Emit your result as exactly two things, in this order:')
    [void]$lines.Add('')
    [void]$lines.Add('1. A standalone line that is nothing but the challenge prefix and this attempt''s nonce:')
    [void]$lines.Add('')
    [void]$lines.Add('```text')
    [void]$lines.Add("$script:ReviewerResponseNoncePrefixV2 $Nonce")
    [void]$lines.Add('```')
    [void]$lines.Add('')
    [void]$lines.Add("2. A line beginning with ``$script:ReviewerResponsePayloadPrefixV2`` followed by one closed JSON object:")
    [void]$lines.Add('')
    [void]$lines.Add('```text')
    [void]$lines.Add("$script:ReviewerResponsePayloadPrefixV2 {""schemaVersion"":2,""reviewedSourceCommit"":""$SourceCommit""," +
        '"findings":[{"severity":"<critical|important|suggestion>","filePath":"<repo-root path or empty>","line":<int>,"comment":"<one plain-text line>"}],' +
        '"recommendedVote":"<approve|approveWithSuggestions|waitForAuthor|none>","summary":"<one plain-text line>"}')
    [void]$lines.Add('```')
    [void]$lines.Add('')
    [void]$lines.Add("The payload object is closed: those five keys, no others. It carries no PR id, no repository, no " +
        'project and no hashes - the wrapper owns all of those and will not read them from you.')
    [void]$lines.Add("Report at most $MaxFindings findings.")
    [void]$lines.Add('You may restate the nonce line and the payload later in the same reply, but every restatement must be identical.')
    [void]$lines.Add('')
    [void]$lines.Add('The nonce line and the payload are read independently. If you emit the payload without the nonce ' +
        'line, your review is still recorded and still read by the other reviewers, but it cannot be cast as a vote ' +
        'and cannot mark this pull request reviewed. Emit the nonce line.')
    [void]$lines.Add('Copy the nonce exactly. A value that is not this attempt''s nonce ends the attempt outright, and ' +
        'so does restating either the nonce or the payload differently the second time.')
    [void]$lines.Add('Do not put the nonce inside the payload object; it belongs on its own line and nowhere else.')
    [void]$lines.Add('Use no tools this cycle.')
    return ($lines.ToArray() -join "`n")
}
