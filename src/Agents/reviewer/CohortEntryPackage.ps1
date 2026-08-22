#!/usr/bin/env pwsh
<#
.SYNOPSIS
    The capture, assembly and immutable publication half of the typed
    cohort-entry evidence builder.

.DESCRIPTION
    CohortEntryEvidence.ps1 decides what may be read and what the answers have to
    prove. This file issues those reads through the reviewed read seam, stores
    every answer in the exact resource envelope the reviewer will later ask for it
    in, assembles the typed entry package a C# cohort manifest accepts unchanged,
    and publishes it atomically as read-only, inventoried, HMAC-authenticated
    private evidence.

    THE ENVELOPE IS NOT RE-DESCRIBED HERE. Every stored response goes through
    New-ReviewerCorpusSealEnvelope, the reviewed function the corpus sealer
    already uses, so there is exactly one definition in this toolkit of what "the
    bytes the replay loader serves" are. A second definition here would be a
    second thing to keep in step, and the class of defect this whole file exists
    to remove is exactly that.

    NOTHING HERE STARTS A MODEL. The only child process this file ever starts is
    the typed coordinator in a preparation-only target, and the reviewer in its
    own no-model source-transport capture mode. Neither consumes a slot, a launch
    token or a model start, and the published package records the evidence that
    neither did.
#>

Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'CohortEntryEvidence.ps1')

# ---------------------------------------------------------------------------
# Capture through the reviewed read seam
# ---------------------------------------------------------------------------

function Get-ReviewerCohortEntryTextPayload {
    <#
    .SYNOPSIS
        The exact bytes one text-content read returned, plus the parsed value.

    .DESCRIPTION
        The raw text is taken FIRST and the parse is done over those same bytes,
        so the bytes stored in the corpus and the value the identity assertions
        run over cannot be two different things. A response whose content is an
        embedded resource where the plan declared text is CE302: the plan and the
        provider disagree about the envelope, and that disagreement changes the
        request key the reviewer will later compute.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Session,
        [Parameter(Mandatory)]$Read,
        [Parameter(Mandatory)][int]$MaxBytes
    )
    $text = ''
    try {
        $text = [string](Invoke-AgentMcpTool -Session $Session -Name $Read.Tool `
                -Arguments ([hashtable]@{} + $Read.Arguments) -RawText)
    }
    catch {
        $message = [string]$_.Exception.Message
        if ($message.Contains('a replay never falls through to a live read')) {
            New-ReviewerCohortEntryRefusal -Code 'CE307' -Detail "The planned read '$($Read.Id)' is not in the snapshot and a replay does not reach the provider for it: $message"
        }
        if ($message.Contains('a replay never writes and never authorizes a write')) {
            New-ReviewerCohortEntryRefusal -Code 'CE308' -Detail "The planned read '$($Read.Id)' was refused: $message"
        }
        New-ReviewerCohortEntryRefusal -Code 'CE302' -Detail "The planned read '$($Read.Id)' did not answer in its declared envelope: $message"
    }
    $bytes = $script:ReviewerCohortEntryUtf8.GetBytes($text)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        New-ReviewerCohortEntryRefusal -Code 'CE306' -Detail "The read '$($Read.Id)' answered with a byte-order mark."
    }
    if ($bytes.Length -gt $MaxBytes) {
        New-ReviewerCohortEntryRefusal -Code 'CE305' `
            -Detail "The read '$($Read.Id)' answered with $($bytes.Length) bytes, over the declared cap of $MaxBytes."
    }
    $parsed = $null
    # -NoEnumerate, deliberately. A wrapper tool that answers a top-level JSON
    # ARRAY - which 'repo_pull_request_thread list' does - is unrolled by the
    # pipeline into its elements, so a one-thread pull request would arrive here
    # as a bare thread object and a many-thread one as a loose element stream.
    # Either way the array shape is destroyed before any contract check can see
    # it, which is exactly the class of defect this builder exists to refuse.
    try { $parsed = ConvertFrom-Json -InputObject $text -Depth 64 -NoEnumerate }
    catch {
        New-ReviewerCohortEntryRefusal -Code 'CE303' `
            -Detail "The read '$($Read.Id)' answered with text that is not a wrapper-contract JSON result: $($_.Exception.Message)"
    }
    return [pscustomobject][ordered]@{
        Bytes = $bytes
        Text = $text
        Parsed = $parsed
    }
}

function Get-ReviewerCohortEntryResourcePayload {
    <#
    .SYNOPSIS
        The exact bytes one embedded-resource read returned, checked against the
        wrapper-requested URI and MIME type.

    .DESCRIPTION
        Reached through the harness's own embedded-resource reader rather than by
        decoding the blob here, so the URI equality, the MIME allow-list, the
        canonical-base64 check, the byte cap, the byte-order-mark refusal and the
        control-character refusal are the reviewer's rules rather than a second
        set that agrees with them today.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Session,
        [Parameter(Mandatory)]$Read,
        [Parameter(Mandatory)][int]$MaxBytes
    )
    $result = $null
    try {
        $result = Send-AgentMcpRequest -Session $Session -Method 'tools/call' `
            -Params @{ name = $Read.Tool; arguments = ([hashtable]@{} + $Read.Arguments) }
    }
    catch {
        $message = [string]$_.Exception.Message
        if ($message.Contains('a replay never falls through to a live read')) {
            New-ReviewerCohortEntryRefusal -Code 'CE307' -Detail "The planned read '$($Read.Id)' is not in the snapshot and a replay does not reach the provider for it: $message"
        }
        if ($message.Contains('a replay never writes and never authorizes a write')) {
            New-ReviewerCohortEntryRefusal -Code 'CE308' -Detail "The planned read '$($Read.Id)' was refused: $message"
        }
        New-ReviewerCohortEntryRefusal -Code 'CE302' -Detail "The planned read '$($Read.Id)' did not answer: $message"
    }
    $resource = $null
    try {
        $resource = ConvertFrom-AgentMcpResourceContent -ToolResult $result -ExpectedUri $Read.ResourceUri `
            -MaxBytes $MaxBytes -AllowedMimeTypes @([string]$Read.MimeType)
    }
    catch {
        $message = [string]$_.Exception.Message
        if ($message.Contains('URI did not exactly match')) {
            New-ReviewerCohortEntryRefusal -Code 'CE304' -Detail "The read '$($Read.Id)' answered under another URI: $message"
        }
        if ($message.Contains('byte-order mark')) {
            New-ReviewerCohortEntryRefusal -Code 'CE306' -Detail "The read '$($Read.Id)' answered with a byte-order mark."
        }
        if ($message.Contains('expected 1..')) {
            New-ReviewerCohortEntryRefusal -Code 'CE305' -Detail "The read '$($Read.Id)' exceeded the declared byte cap: $message"
        }
        New-ReviewerCohortEntryRefusal -Code 'CE302' `
            -Detail "The read '$($Read.Id)' did not answer in an embedded-resource envelope: $message"
    }
    return [pscustomobject][ordered]@{
        Bytes = $script:ReviewerCohortEntryUtf8.GetBytes([string]$resource.Text)
        Text = [string]$resource.Text
        Sha256 = [string]$resource.Sha256
        ByteLength = [int]$resource.ByteLength
    }
}

function Invoke-ReviewerCohortEntryRead {
    <#
    .SYNOPSIS
        Issues ONE planned read and returns the record the corpus, the recipe and
        the census are all built from.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Session,
        [Parameter(Mandatory)]$Read,
        [Parameter(Mandatory)][int]$MaxBytes
    )
    if ($Read.Envelope -ceq 'mcpResourceContent') {
        $payload = Get-ReviewerCohortEntryResourcePayload -Session $Session -Read $Read -MaxBytes $MaxBytes
        return [pscustomobject][ordered]@{
            Read = $Read
            Bytes = $payload.Bytes
            Text = $payload.Text
            Parsed = $null
            Sha256 = (Get-ReviewerCorpusSealSha256 -Bytes $payload.Bytes)
            ByteLength = [int]$payload.Bytes.Length
        }
    }
    $payload = Get-ReviewerCohortEntryTextPayload -Session $Session -Read $Read -MaxBytes $MaxBytes
    return [pscustomobject][ordered]@{
        Read = $Read
        Bytes = $payload.Bytes
        Text = $payload.Text
        Parsed = $payload.Parsed
        Sha256 = (Get-ReviewerCorpusSealSha256 -Bytes $payload.Bytes)
        ByteLength = [int]$payload.Bytes.Length
    }
}

function Assert-ReviewerCohortEntryReadsComplete {
    <#
    .SYNOPSIS
        Requires the captured set to be exactly the planned set - no read
        missing, no read that was never planned.

    .DESCRIPTION
        Both directions, because both have happened. A missing read leaves the
        reviewer with a request nobody recorded; an extra read means this build
        went somewhere the plan does not describe, and a corpus containing an
        unplanned response is a corpus whose contents nobody authorized.
    #>
    param(
        [Parameter(Mandatory)][object[]]$Plan,
        [Parameter(Mandatory)][object[]]$Captured
    )
    # Cardinality-exact, not set-membership. A build that issued one planned read
    # TWICE has performed a read the plan does not describe just as surely as one
    # that invented a new id, and comparing sets would call both of them equal.
    # Named 'performed' rather than 'captured' deliberately: PowerShell variable
    # names are case-insensitive, so a local $captured IS the [object[]]$Captured
    # parameter, and assigning a dictionary to it silently coerces the dictionary
    # into an array instead of shadowing it.
    $planned = [System.Collections.Generic.Dictionary[string, int]]::new([StringComparer]::Ordinal)
    foreach ($read in $Plan) {
        $id = [string]$read.Id
        $planned[$id] = $(if ($planned.ContainsKey($id)) { $planned[$id] + 1 } else { 1 })
    }
    $performed = [System.Collections.Generic.Dictionary[string, int]]::new([StringComparer]::Ordinal)
    foreach ($record in $Captured) {
        $id = [string]$record.Read.Id
        $performed[$id] = $(if ($performed.ContainsKey($id)) { $performed[$id] + 1 } else { 1 })
    }
    $missing = [string[]]@($planned.Keys | Where-Object { -not $performed.ContainsKey($_) })
    if ($missing.Count -gt 0) {
        New-ReviewerCohortEntryRefusal -Code 'CE300' -Detail "Never performed: $(($missing | Sort-Object) -join ', ')."
    }
    $extra = [string[]]@($performed.Keys | Where-Object { -not $planned.ContainsKey($_) })
    if ($extra.Count -gt 0) {
        New-ReviewerCohortEntryRefusal -Code 'CE301' -Detail "Performed but never planned: $(($extra | Sort-Object) -join ', ')."
    }
    foreach ($id in $planned.Keys) {
        if ($performed[$id] -ne $planned[$id]) {
            New-ReviewerCohortEntryRefusal -Code 'CE301' `
                -Detail "The read '$id' is planned $($planned[$id]) time(s) and was performed $($performed[$id]) time(s)."
        }
    }
}

# ---------------------------------------------------------------------------
# Corpus, recipe and index inputs
# ---------------------------------------------------------------------------

function Get-ReviewerCohortEntryCorpusRelativePath {
    <#
    .SYNOPSIS
        The corpus-relative path one captured read's payload is stored at.

    .DESCRIPTION
        Derived from the read's declared role and ordinal position rather than
        from the provider path, because a provider path may contain characters a
        filesystem will not take and two provider paths may normalize to one
        filesystem path on a case-insensitive volume - which is how one corpus
        once silently held one file where two were captured.
    #>
    param(
        [Parameter(Mandatory)]$Read,
        [Parameter(Mandatory)][int]$Ordinal
    )
    $suffix = $Ordinal.ToString('000', [Globalization.CultureInfo]::InvariantCulture)
    switch -CaseSensitive ($Read.Role) {
        'changedFile' { return "files/$suffix.txt" }
        'sibling' { return "evidence/siblings/$suffix.txt" }
        'rule' { return "evidence/rules/$suffix.txt" }
    }
    return [string]$Read.PayloadFile
}

function New-ReviewerCohortEntryCorpus {
    <#
    .SYNOPSIS
        Writes the private corpus and mints its index, in the exact bytes the
        typed C# stager mints for the same declaration.

    .DESCRIPTION
        The index is rendered through the toolkit's own canonical JSON writer
        with payloads in ascending ordinal path order. That is the whole reason
        one seal recipe can bind a corpus this builder wrote and a corpus the
        typed stager staged: they are the same BYTES, not merely the same
        contents.
    #>
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Files,
        [Parameter(Mandatory)]$Request,
        [Parameter(Mandatory)]$Identity,
        [Parameter(Mandatory)][int]$IterationId
    )
    [void](New-Item -ItemType Directory -Force -Path $Root)
    $ordered = [string[]]@($Files.Keys)
    [Array]::Sort($ordered, [StringComparer]::Ordinal)

    $entries = [System.Collections.Generic.List[object]]::new()
    foreach ($relative in $ordered) {
        $full = $Root
        $segments = [string[]]@($relative -split '/')
        foreach ($segment in $segments) { $full = Join-Path $full $segment }
        [void](New-Item -ItemType Directory -Force -Path (Split-Path $full -Parent))
        $bytes = [byte[]]$Files[$relative]
        [IO.File]::WriteAllBytes($full, $bytes)
        [void]$entries.Add([ordered]@{
                path = $relative
                sha256 = (Get-ReviewerCorpusSealSha256 -Bytes $bytes)
                length = $bytes.Length
            })
    }
    $identities = [ordered]@{}
    $identities["$($Request.PullRequestId)"] = [ordered]@{
        pullRequestId = $Request.PullRequestId
        iteration = $IterationId
        source = $Identity.SourceCommit
        common = $Identity.CommonCommit
        target = $Identity.TargetCommit
        status = $Identity.Status
        isDraft = $Identity.IsDraft
    }
    $index = [ordered]@{
        kind = 'private-immutable-non-promotable-research-corpus'
        repository = "$($Request.Organization)/$($Request.Project)/$($Request.RepositoryName)"
        payloadCount = $entries.Count
        identities = $identities
        payloads = [object[]]$entries.ToArray()
    }
    $indexPath = Join-Path $Root 'corpus-index.json'
    [IO.File]::WriteAllBytes($indexPath,
        $script:ReviewerCohortEntryUtf8.GetBytes((ConvertTo-AgentReplayCanonicalJson -Value $index)))
    return [pscustomobject][ordered]@{
        Root = [string]([IO.Path]::GetFullPath($Root))
        IndexPath = [string]([IO.Path]::GetFullPath($indexPath))
        IndexSha256 = (Get-FileHash -LiteralPath $indexPath -Algorithm SHA256).Hash.ToLowerInvariant()
        PayloadCount = $entries.Count
    }
}

function New-ReviewerCohortEntryResourceDeclaration {
    <#
    .SYNOPSIS
        One recipe resource declaration for one captured read, carrying the exact
        tool, the exact arguments, the declared envelope, the wrapper-requested
        URI and the digest and length the sealed payload must have.
    #>
    param(
        [Parameter(Mandatory)]$Captured,
        [Parameter(Mandatory)][string]$CorpusRelativePath
    )
    $read = $Captured.Read
    return [ordered]@{
        tool = [string]$read.Tool
        arguments = $read.Arguments
        envelope = [string]$read.Envelope
        payloadFile = [string]$read.PayloadFile
        corpusPayload = [ordered]@{
            path = $CorpusRelativePath
            sha256 = [string]$Captured.Sha256
            byteLength = [int]$Captured.ByteLength
        }
        resourceUri = [string]$read.ResourceUri
        mimeType = [string]$read.MimeType
        expected = [ordered]@{
            payloadSha256 = [string]$Captured.Sha256
            payloadByteLength = [int]$Captured.ByteLength
        }
    }
}

function Test-ReviewerCohortEntryEnvelopeRoundTrip {
    <#
    .SYNOPSIS
        Whether the reviewed envelope function, given one captured payload,
        produces bytes the replay loader would serve for exactly this read key.

    .DESCRIPTION
        This is the check that makes "stored in the exact envelope the reviewer
        requests" a proved property rather than an intention. The bytes are built
        by the sealer's own envelope function and then re-parsed under the
        harness's own tool-result predicate: a payload that seals cleanly and
        cannot be read back is exactly the defect a hand-assembled corpus keeps
        producing, and it is invisible until a run needs the bytes.
    #>
    param(
        [Parameter(Mandatory)]$Captured
    )
    $read = $Captured.Read
    $payload = @{
        Path = [string]$read.PayloadFile
        Bytes = [byte[]]$Captured.Bytes
        ByteLength = [int]$Captured.ByteLength
        Sha256 = [string]$Captured.Sha256
    }
    $envelopeBytes = $null
    try {
        $envelopeBytes = New-ReviewerCorpusSealEnvelope -Envelope ([string]$read.Envelope) -Payload $payload `
            -ResourceUri ([string]$read.ResourceUri) -MimeType ([string]$read.MimeType)
    }
    catch {
        New-ReviewerCohortEntryRefusal -Code 'CE302' `
            -Detail "The read '$($read.Id)' cannot be stored in its declared '$($read.Envelope)' envelope: $($_.Exception.Message)"
    }
    $envelopeText = $script:ReviewerCohortEntryUtf8.GetString($envelopeBytes)
    $envelope = $null
    try { $envelope = $envelopeText | ConvertFrom-Json -Depth 64 }
    catch {
        New-ReviewerCohortEntryRefusal -Code 'CE302' -Detail "The sealed envelope for '$($read.Id)' is not readable JSON."
    }
    if (-not (Test-AgentMcpToolResultShape -Result $envelope.result)) {
        New-ReviewerCohortEntryRefusal -Code 'CE303' `
            -Detail "The sealed envelope for '$($read.Id)' is not a wrapper-contract tool result no reader could consume."
    }
    return $envelopeBytes
}

# ---------------------------------------------------------------------------
# The typed entry package
# ---------------------------------------------------------------------------

function Get-ReviewerCohortEntryConfigBinding {
    <#
    .SYNOPSIS
        The reviewer configuration's own repository identity and validated target
        ref, read the way the reviewer reads them.

    .DESCRIPTION
        The point of reading it here is the comparison that follows: an entry
        whose configuration targets a different branch from the one its pull
        request merges into runs the wrong rules against the right diff, produces
        a plausible result, and is indistinguishable from a correct run without
        this check.
    #>
    param([Parameter(Mandatory)][string]$ConfigPath)
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        New-ReviewerCohortEntryRefusal -Code 'CE211' -Detail "The reviewer configuration '$ConfigPath' does not exist."
    }
    $bytes = [IO.File]::ReadAllBytes($ConfigPath)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        New-ReviewerCohortEntryRefusal -Code 'CE101' -Detail "The reviewer configuration '$ConfigPath' begins EF BB BF."
    }
    $config = $null
    try { $config = $script:ReviewerCohortEntryUtf8.GetString($bytes) | ConvertFrom-Json -Depth 64 }
    catch {
        New-ReviewerCohortEntryRefusal -Code 'CE211' -Detail "The reviewer configuration '$ConfigPath' is not readable JSON."
    }
    $repository = Get-ReviewerCohortEntryProperty -Object $config -Name 'repository' -Where 'reviewer configuration' -Code 'CE212'
    $review = Get-ReviewerCohortEntryProperty -Object $config -Name 'review' -Where 'reviewer configuration' -Code 'CE211'
    # Read under the name THE REVIEWER READS IT UNDER, and with the reviewer's
    # own shape rule: Start-ReviewerAgent takes config.review.targetRefName and
    # requires a full '^refs/heads/.+$'. A second spelling here would be a second
    # contract, and an entry could then validate against a config the reviewer
    # itself would refuse to start on.
    $validatedRef = [string](Get-ReviewerCohortEntryProperty -Object $review -Name 'targetRefName' -Where 'reviewer configuration review' -Code 'CE211')
    if ($validatedRef -cnotmatch '^refs/heads/.+$') {
        New-ReviewerCohortEntryRefusal -Code 'CE211' `
            -Detail "The reviewer configuration review.targetRefName is '$validatedRef', which is not a full refs/heads ref."
    }
    # Optional by design, and read WITHOUT refusing when absent: a preparation-only
    # entry is complete without them, and only an execution plan makes them
    # load-bearing. Read here rather than in the plan reader so there is exactly
    # one place that knows the reviewer's own spelling of these settings.
    $specialistModel = ''
    if ($review.PSObject.Properties['conventionSpecialistModel']) {
        $specialistModel = [string]$review.conventionSpecialistModel
    }
    $verifierModel = ''
    $verificationEnabled = $false
    if ($review.PSObject.Properties['verification']) {
        $verification = $review.verification
        if ($verification -is [System.Management.Automation.PSCustomObject]) {
            if ($verification.PSObject.Properties['enabled']) {
                # NOT [bool]$verification.enabled. PowerShell reads the string
                # "false" as $true, so a configuration that spelled this as a
                # string would look to the CE706 pairing check like it enabled
                # verification - and the reviewer agent's own reader
                # (Get-AgentConfigBool) would then refuse the same file at
                # startup, after the entry was sealed.
                $enabledValue = $verification.enabled
                if ($enabledValue -isnot [bool]) {
                    New-ReviewerCohortEntryRefusal -Code 'CE211' `
                        -Detail 'The reviewer configuration review.verification.enabled is not a boolean; the reviewer agent reads this field strictly and would refuse it at startup.'
                }
                $verificationEnabled = [bool]$enabledValue
            }
            if ($verification.PSObject.Properties['conventionVerifierModel']) {
                $verifierModel = [string]$verification.conventionVerifierModel
            }
        }
    }
    return [pscustomobject][ordered]@{
        Sha256 = (Get-ReviewerCorpusSealSha256 -Bytes $bytes)
        Organization = [string](Get-ReviewerCohortEntryProperty -Object $repository -Name 'organization' -Where 'reviewer configuration repository' -Code 'CE212')
        Project = [string](Get-ReviewerCohortEntryProperty -Object $repository -Name 'project' -Where 'reviewer configuration repository' -Code 'CE212')
        Name = [string](Get-ReviewerCohortEntryProperty -Object $repository -Name 'name' -Where 'reviewer configuration repository' -Code 'CE212')
        Id = [string](Get-ReviewerCohortEntryProperty -Object $repository -Name 'id' -Where 'reviewer configuration repository' -Code 'CE212')
        ValidatedTargetRef = $validatedRef
        ConventionSpecialistModel = $specialistModel
        ConventionVerifierModel = $verifierModel
        VerificationEnabled = $verificationEnabled
    }
}

function Assert-ReviewerCohortEntryExecutionPlanBinding {
    <#
    .SYNOPSIS
        Requires an execution plan to name the reviewed script that is actually on
        disk, the models the registry actually carries, and the models this
        reviewer configuration actually configures.

    .DESCRIPTION
        Every check here closes a failure that has already happened once at slot
        startup rather than at build time, which is the worst possible place for
        it: by then a run set is declared, a launch token is minted, two slots are
        authorized, and the first one dies on a model identifier nobody can change
        without re-declaring the set.

        The generalist pair is DERIVED from the shared supported-model registry
        and the plan's restatement is compared against it, never trusted. That is
        the whole point of the registry's "newest first" comment: a wrapper that
        names its own version is exactly how a retired Opus reached a slot.
    #>
    param(
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)]$Binding
    )

    if (-not (Test-Path -LiteralPath $Plan.ReviewerScriptPath -PathType Leaf)) {
        New-ReviewerCohortEntryRefusal -Code 'CE703' `
            -Detail "The execution plan reviewer script '$($Plan.ReviewerScriptPath)' does not exist."
    }
    $observed = (Get-FileHash -LiteralPath $Plan.ReviewerScriptPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($observed -cne $Plan.ReviewerScriptSha256) {
        New-ReviewerCohortEntryRefusal -Code 'CE703' `
            -Detail "The execution plan pins the reviewer script at $($Plan.ReviewerScriptSha256) and '$($Plan.ReviewerScriptPath)' hashes to $observed."
    }

    $registry = Get-ReviewerCohortEntryModelRegistry
    foreach ($model in @(@($Plan.GeneralistPair) + @($Plan.ConventionSpecialistModel, $Plan.ConventionVerifierModel))) {
        if (@($registry.Supported) -cnotcontains [string]$model) {
            New-ReviewerCohortEntryRefusal -Code 'CE704' `
                -Detail "The execution plan names model '$model', which the supported-model registry does not carry."
        }
    }
    $derived = [string[]]@($registry.GeneralistPair)
    $declared = [string[]]@($Plan.GeneralistPair)
    for ($i = 0; $i -lt $derived.Count; $i++) {
        if ($declared[$i] -cne $derived[$i]) {
            New-ReviewerCohortEntryRefusal -Code 'CE705' `
                -Detail "The execution plan declares the generalist pair ($($declared -join ', ')) and the registry derives ($($derived -join ', '))."
        }
    }
    # The reviewer refuses at startup when the discovery model is one of the two
    # generalists, because a "second opinion" from a model that already voted is
    # not one. Refused here so the refusal arrives before a run set exists.
    if ($derived -ccontains $Plan.ConventionSpecialistModel) {
        New-ReviewerCohortEntryRefusal -Code 'CE705' `
            -Detail "The execution plan uses generalist '$($Plan.ConventionSpecialistModel)' as the convention specialist; the specialist must differ from both."
    }

    if ([string]::IsNullOrEmpty($Binding.ConventionSpecialistModel)) {
        New-ReviewerCohortEntryRefusal -Code 'CE706' `
            -Detail 'The reviewer configuration declares no review.conventionSpecialistModel, so an execution plan cannot be checked against it.'
    }
    if ($Plan.ConventionSpecialistModel -cne $Binding.ConventionSpecialistModel) {
        New-ReviewerCohortEntryRefusal -Code 'CE706' `
            -Detail "The execution plan uses specialist '$($Plan.ConventionSpecialistModel)' and the reviewer configuration configures '$($Binding.ConventionSpecialistModel)'."
    }
    if (-not $Binding.VerificationEnabled) {
        New-ReviewerCohortEntryRefusal -Code 'CE706' `
            -Detail 'The execution plan declares a convention verifier and the reviewer configuration disables review.verification; the agent would refuse the pairing at startup.'
    }
    if ($Plan.ConventionVerifierModel -cne $Binding.ConventionVerifierModel) {
        New-ReviewerCohortEntryRefusal -Code 'CE706' `
            -Detail "The execution plan uses verifier '$($Plan.ConventionVerifierModel)' and the reviewer configuration configures '$($Binding.ConventionVerifierModel)'."
    }
}

function Assert-ReviewerCohortEntryConfigBinding {
    <#
    .SYNOPSIS
        Requires the reviewer configuration to be the configuration for THIS
        subject and THIS target ref.
    #>
    param(
        [Parameter(Mandatory)]$Binding,
        [Parameter(Mandatory)]$Request
    )
    foreach ($pair in @(
            @{ Name = 'organization'; Observed = $Binding.Organization; Declared = $Request.Organization },
            @{ Name = 'project'; Observed = $Binding.Project; Declared = $Request.Project },
            @{ Name = 'name'; Observed = $Binding.Name; Declared = $Request.RepositoryName })) {
        if ([string]$pair.Observed -cne [string]$pair.Declared) {
            New-ReviewerCohortEntryRefusal -Code 'CE212' `
                -Detail "The reviewer configuration's repository.$($pair.Name) is '$([string]$pair.Observed)' and the request declares '$([string]$pair.Declared)'."
        }
    }
    if ([string]$Binding.Id -ine [string]$Request.RepositoryId) {
        New-ReviewerCohortEntryRefusal -Code 'CE212' `
            -Detail "The reviewer configuration's repository.id is '$([string]$Binding.Id)' and the request declares '$($Request.RepositoryId)'."
    }
    if ([string]$Binding.ValidatedTargetRef -cne [string]$Request.TargetRefName) {
        New-ReviewerCohortEntryRefusal -Code 'CE211' `
            -Detail "The reviewer configuration validates target '$([string]$Binding.ValidatedTargetRef)' and this pull request merges into '$($Request.TargetRefName)'."
    }
}

function New-ReviewerCohortEntryCoordinatorRequest {
    <#
    .SYNOPSIS
        The typed coordinator request this entry pins, in the exact contract the
        C# reader accepts.

    .DESCRIPTION
        Written with NO slots section when the request carries no execution plan.
        An entry that build produces authorizes a preparation and nothing else:
        there is no way to add a slot afterwards, because a request that grew one
        would be a different request and its digest - which is the digest the
        entry pins - would no longer match.

        When the request DOES carry an execution plan, the whole run declaration
        is written here, in this one object, before anything is hashed: two
        declared slots, the reconciliation that compares them and a preview-only
        delivery. That ordering is the entire security property. The coordinator
        digests the request file as a whole, the manifest entry pins that digest,
        and both are computed after this function returns - so a slot appended
        afterwards changes the digest the entry pins and is refused by the typed
        reader before it reads a single field.
    #>
    param(
        [Parameter(Mandatory)]$Request,
        [Parameter(Mandatory)]$Identity,
        [Parameter(Mandatory)][int]$IterationId,
        [Parameter(Mandatory)]$Corpus,
        [Parameter(Mandatory)][string]$RecipePath,
        [Parameter(Mandatory)][string]$ChangedPathsPath,
        [Parameter(Mandatory)][string]$CorpusRoot,
        [Parameter(Mandatory)][string]$ConfigSha256,
        [Parameter(Mandatory)][string]$PromptSha256,
        [Parameter(Mandatory)][string]$SchemaSha256,
        [Parameter(Mandatory)][string]$PreparationOutputRoot
    )
    $emitted = [ordered]@{
        contractVersion = $script:ReviewerCohortEntryCoordinatorContract
        kind = 'shadow-run-preparation'
        correlationId = $Request.CorrelationId
        toolkit = [ordered]@{ repositoryRoot = $Request.ToolkitRoot; head = $Request.ToolkitHead }
        subject = [ordered]@{
            organization = $Request.Organization
            project = $Request.Project
            repository = $Request.RepositoryName
            pullRequestId = $Request.PullRequestId
            iterationId = $IterationId
            sourceCommit = $Identity.SourceCommit
            commonCommit = $Identity.CommonCommit
            targetCommit = $Identity.TargetCommit
        }
        digests = [ordered]@{
            configSha256 = $ConfigSha256
            promptSha256 = $PromptSha256
            schemaSha256 = $SchemaSha256
        }
        corpus = [ordered]@{
            root = $CorpusRoot
            indexSha256 = $Corpus.IndexSha256
            recipePath = $RecipePath
            changedPathsPath = $ChangedPathsPath
        }
        output = [ordered]@{ root = $PreparationOutputRoot }
        children = [ordered]@{
            powerShellPath = $Request.PowerShellPath
            timeoutSeconds = $Request.ChildTimeoutSeconds
        }
        qualification = [ordered]@{
            operatorAlias = $Request.OperatorAlias
            reviewerConfigPath = $Request.ReviewerConfigPath
            reviewerRepositoryPath = $Request.ReviewerRepositoryPath
            expectedCommit = $Request.ToolkitHead
            requiredRef = $Request.RequiredRef
            plannedRunCount = $Request.PlannedRunCount
            runSetKeyPath = $Request.RunSetKeyPath
        }
    }

    $plan = $Request.ExecutionPlan
    if ($null -eq $plan) { return $emitted }

    # Every output directory is JOINED under the preparation root rather than
    # taken from the request, so the only thing an operator supplied is a leaf
    # name. There is no string they can write that reaches outside this root -
    # not '..', not a rooted path, not another volume - because none of what they
    # wrote is used as a path.
    $preparationRoot = [IO.Path]::GetFullPath($PreparationOutputRoot)
    $reconciliationDirectory = [IO.Path]::GetFullPath((Join-Path $preparationRoot $plan.ReconciliationOutputDirName))
    $deliveryDirectory = [IO.Path]::GetFullPath((Join-Path $preparationRoot $plan.DeliveryOutputDirName))
    foreach ($directory in @($reconciliationDirectory, $deliveryDirectory)) {
        if (-not (Test-ReviewerCohortEntryPathWithin -Candidate $directory -Root $preparationRoot)) {
            New-ReviewerCohortEntryRefusal -Code 'CE711' `
                -Detail "The emitted output directory '$directory' is outside the preparation root '$preparationRoot'."
        }
    }

    $declared = [object[]]@(foreach ($slot in @($plan.Slots)) {
            [ordered]@{
                name = $slot.Name
                # ONE script for both slots, by construction rather than by
                # comparison: two slots running different reviewers are not two
                # passes of the same reviewer, and the typed reader refuses a pair
                # whose paths differ at all.
                reviewerScriptPath = $plan.ReviewerScriptPath
                launchAuthorizationTokenPath = $slot.LaunchAuthorizationTokenPath
                supervisionGraceSeconds = $plan.SupervisionGraceSeconds
                stateDirName = $slot.StateDirName
                terminalName = $slot.TerminalName
                modelPlan = [ordered]@{
                    bindSealedArguments = $slot.BindSealedArguments
                    opaqueArguments = [object[]]@($slot.OpaqueArguments)
                }
            }
        })

    $emitted['slots'] = [ordered]@{
        shadowSlotsEnabled = $true
        declared = $declared
        reconciliation = [ordered]@{
            reconciliationEnabled = $true
            outputDirectory = $reconciliationDirectory
            requiredRunCount = $declared.Count
            launchAuthorizationTokenPath = $plan.ReconciliationTokenPath
            supervisionGraceSeconds = $plan.SupervisionGraceSeconds
        }
        delivery = [ordered]@{
            deliveryEnabled = $true
            authorizationKind = 'PreviewOnly'
            outputDirectory = $deliveryDirectory
            requiredRunCount = $declared.Count
            launchAuthorizationTokenPath = $plan.DeliveryTokenPath
            supervisionGraceSeconds = $plan.SupervisionGraceSeconds
            # Written as values rather than left out. An absent capability is a
            # capability the next reader gets to decide about; a capability
            # written false is one nobody can reinterpret.
            commentsEnabled = $false
            votesEnabled = $false
            gatesEnabled = $false
            providerWriteBudget = 0
        }
    }
    return $emitted
}

function New-ReviewerCohortEntryManifestEntry {
    <#
    .SYNOPSIS
        The cohort manifest entry itself, in the exact v3 shape the C# reader
        parses, so a manifest can embed this object with no translation at all.

    .DESCRIPTION
        Every field here is one the typed reader requires by name, in the section
        it requires it in. That is the point of this whole build: the operator
        never writes this object, so the operator can never write it wrong, and
        the acceptance test for the whole builder is that a manifest containing
        exactly this object loads.
    #>
    param(
        [Parameter(Mandatory)]$Request,
        [Parameter(Mandatory)]$Identity,
        [Parameter(Mandatory)][int]$IterationId,
        [Parameter(Mandatory)][string]$CoordinatorRequestPath,
        [Parameter(Mandatory)][string]$CoordinatorRequestSha256,
        [Parameter(Mandatory)][string]$PreparationOutputRoot,
        [Parameter(Mandatory)][string]$ConfigSha256,
        [Parameter(Mandatory)][string]$PromptSha256,
        [Parameter(Mandatory)][string]$SchemaSha256,
        [Parameter(Mandatory)][string]$ModelStartBoundPath,
        [Parameter(Mandatory)][string]$ModelStartBoundSha256,
        [Parameter(Mandatory)][int]$EstimatedModelStarts,
        [Parameter(Mandatory)][int]$EstimatedVerifierAssignments,
        [Parameter(Mandatory)][int]$EstimatedWallClockSeconds
    )
    return [ordered]@{
        ordinal = $Request.Ordinal
        entryId = $Request.EntryId
        request = [ordered]@{ path = $CoordinatorRequestPath; sha256 = $CoordinatorRequestSha256 }
        output = [ordered]@{ root = $PreparationOutputRoot }
        subject = [ordered]@{
            organization = $Request.Organization
            project = $Request.Project
            repository = $Request.RepositoryName
            pullRequestId = $Request.PullRequestId
            iterationId = $IterationId
            sourceCommit = $Identity.SourceCommit
            commonCommit = $Identity.CommonCommit
            targetCommit = $Identity.TargetCommit
            targetRefName = $Request.TargetRefName
        }
        digests = [ordered]@{
            configSha256 = $ConfigSha256
            promptSha256 = $PromptSha256
            schemaSha256 = $SchemaSha256
        }
        ruleBundle = [ordered]@{
            sourceKind = $Request.RuleBundleSourceKind
            declarationPath = $Request.RuleBundleDeclarationPath
            declarationSha256 = $Request.RuleBundleDeclarationSha256
        }
        planEstimate = [ordered]@{
            modelStarts = $EstimatedModelStarts
            verifierAssignments = $EstimatedVerifierAssignments
            wallClockSeconds = $EstimatedWallClockSeconds
            modelStartBound = [ordered]@{ path = $ModelStartBoundPath; sha256 = $ModelStartBoundSha256 }
        }
    }
}

function New-ReviewerCohortEntryModelStartBound {
    <#
    .SYNOPSIS
        The derived model-start bound for the request this entry emitted, taken
        by the reviewed producer and never restated here.

    .DESCRIPTION
        There is exactly ONE derivation of this number in the tree, and it is not
        this function: `tools/New-ShadowModelStartBound.ps1` reads the sealed
        request, re-hashes the reviewer config the request pins, rebuilds each
        declared slot's argument vector with the reviewed builder the run itself
        will use, and multiplies the per-role attempt bounds out of the
        reviewer's own sources and verification policy. This function invokes
        that producer over the request that was actually written and publishes
        its artifact verbatim.

        It is invoked as a CHILD process rather than dot-sourced. The producer
        imports the harness and dot-sources three reviewer modules; loading those
        into the builder's own session would redefine functions the builder is
        mid-way through using. A child cannot do that, and it launches no model:
        the vector is built with placeholder model identifiers precisely because
        counting launches never needs to know which model makes them.

        A bound that could not be derived is not defaulted, estimated or skipped.
        The entry that would have carried it is refused, because an entry whose
        budget is a placeholder is the under-declaration the cohort runner exists
        to refuse - and refusing it here costs an operator a rebuild, while
        admitting it costs a cohort its ceiling.

        A pre-derived artifact may be supplied, but it is an EXPECTATION rather
        than a substitute: the producer still runs, and every number the supplied
        file states has to be the number this build derives. Admitting a supplied
        artifact on its bindings alone would admit any artifact carrying the
        right labels and the wrong maxima - kind, request digest, head and slot
        count are all copyable out of a legitimate bound, and lowering the maxima
        underneath them cannot be caught downstream: the estimate is taken FROM
        the maxima, so it can never contradict them, and the cohort runner sizes
        its ceiling from the same file. The overspend would then be noticed only
        after the models had run. So the only supplied bound this accepts is the
        one it derives anyway, and supplying it proves a build reproduces a
        number rather than asserting one. What is published is always the
        artifact this build derived, never the one it was handed.
    #>
    param(
        [Parameter(Mandatory)][string]$ToolkitRoot,
        [Parameter(Mandatory)][string]$ToolkitHead,
        [Parameter(Mandatory)][string]$RequestPath,
        [Parameter(Mandatory)][string]$RequestSha256,
        [Parameter(Mandatory)][string]$OutputPath,
        [string]$BoundArtifactPath = ''
    )
    $supplied = $null
    if ($BoundArtifactPath) {
        if (-not (Test-Path -LiteralPath $BoundArtifactPath -PathType Leaf)) {
            New-ReviewerCohortEntryRefusal -Code 'CE714' `
                -Detail "The pre-derived model start bound '$BoundArtifactPath' does not exist."
        }
        try {
            $suppliedText = $script:ReviewerCohortEntryUtf8.GetString([IO.File]::ReadAllBytes($BoundArtifactPath))
            $supplied = ConvertFrom-Json -InputObject $suppliedText -Depth 32
        }
        catch {
            New-ReviewerCohortEntryRefusal -Code 'CE714' `
                -Detail "The pre-derived model start bound '$BoundArtifactPath' is not readable UTF-8 JSON."
        }
        # `null`, `false`, `0`, `[]` and `""` are all well-formed JSON that parse
        # to something falsy, and a truncated or half-written artifact is exactly
        # what an operator hands to a reproducibility check. Keying the
        # comparison below on the parsed value would let those skip it silently -
        # a gate reporting success without running. Supplied-ness comes from the
        # path; the parse has to have produced an object.
        if ($supplied -isnot [System.Management.Automation.PSCustomObject]) {
            New-ReviewerCohortEntryRefusal -Code 'CE714' `
                -Detail "The pre-derived model start bound '$BoundArtifactPath' is not a JSON object."
        }
    }

    $producer = Join-Path $ToolkitRoot 'tools/New-ShadowModelStartBound.ps1'
    if (-not (Test-Path -LiteralPath $producer -PathType Leaf)) {
        New-ReviewerCohortEntryRefusal -Code 'CE714' `
            -Detail "The model start bound producer '$producer' is not in the pinned toolkit, so no bound can be derived."
    }
    $shell = Join-Path $PSHOME 'pwsh.exe'
    if (-not (Test-Path -LiteralPath $shell -PathType Leaf)) { $shell = 'pwsh' }
    $stdErrPath = "$OutputPath.stderr"
    $previousNative = $PSNativeCommandUseErrorActionPreference
    $PSNativeCommandUseErrorActionPreference = $false
    try {
        $null = & $shell -NoProfile -NonInteractive -File $producer `
            -RequestPath $RequestPath -OutputPath $OutputPath -Force 2>$stdErrPath
    }
    finally { $PSNativeCommandUseErrorActionPreference = $previousNative }
    $producerExit = $LASTEXITCODE
    $stdErr = ''
    if (Test-Path -LiteralPath $stdErrPath -PathType Leaf) {
        $stdErr = ([IO.File]::ReadAllText($stdErrPath)).Trim()
        Remove-Item -LiteralPath $stdErrPath -Force -ErrorAction SilentlyContinue
    }
    if ($producerExit -ne 0 -or -not (Test-Path -LiteralPath $OutputPath -PathType Leaf)) {
        New-ReviewerCohortEntryRefusal -Code 'CE714' `
            -Detail "The model start bound producer exited $producerExit over '$RequestPath': $stdErr"
    }
    $derivedSha = (Get-FileHash -LiteralPath $OutputPath -Algorithm SHA256).Hash.ToLowerInvariant()

    # Re-read what was published, rather than what was asked for. The producer
    # is a separate process over a separate contract; the only thing that makes
    # its artifact this entry's bound is that the artifact says so.
    $boundText = ''
    try { $boundText = $script:ReviewerCohortEntryUtf8.GetString([IO.File]::ReadAllBytes($OutputPath)) }
    catch {
        New-ReviewerCohortEntryRefusal -Code 'CE714' -Detail "The derived model start bound at '$OutputPath' is not UTF-8 without a byte-order mark."
    }
    $bound = $null
    try { $bound = ConvertFrom-Json -InputObject $boundText -Depth 32 }
    catch {
        New-ReviewerCohortEntryRefusal -Code 'CE714' -Detail "The derived model start bound at '$OutputPath' is not readable JSON."
    }
    $kind = [string](Get-ReviewerCohortEntryProperty -Object $bound -Name 'kind' -Where 'derived model start bound' -Code 'CE714')
    if ($kind -cne $script:ReviewerCohortEntryModelStartBoundKind) {
        New-ReviewerCohortEntryRefusal -Code 'CE714' `
            -Detail "The derived model start bound declares kind '$kind'; the cohort runner reads '$($script:ReviewerCohortEntryModelStartBoundKind)' only."
    }
    $boundRequestSha = ([string](Get-ReviewerCohortEntryProperty -Object $bound -Name 'requestSha256' -Where 'derived model start bound' -Code 'CE714')).ToLowerInvariant()
    if ($boundRequestSha -cne $RequestSha256) {
        New-ReviewerCohortEntryRefusal -Code 'CE714' `
            -Detail "The derived model start bound was taken over a request digesting to $boundRequestSha; this entry emitted $RequestSha256."
    }
    $boundHead = [string](Get-ReviewerCohortEntryProperty -Object $bound -Name 'toolkitHead' -Where 'derived model start bound' -Code 'CE714')
    if ($boundHead -cne $ToolkitHead) {
        New-ReviewerCohortEntryRefusal -Code 'CE714' `
            -Detail "The derived model start bound was taken at toolkit head $boundHead; this entry pins $ToolkitHead."
    }
    # The per-attempt limits the bound multiplies live in the toolkit, so a
    # bound is only this build's bound while both of those hold.
    $maxima = [ordered]@{}
    foreach ($field in @('maxRealModelStarts', 'maxVerifierAssignments')) {
        $value = Get-ReviewerCohortEntryProperty -Object $bound -Name $field -Where 'derived model start bound' -Code 'CE714'
        $parsed = 0
        if ($null -eq $value -or $value -is [string] -or -not [int]::TryParse([string]$value, [ref]$parsed) -or
            $parsed -lt 0 -or $parsed -gt 65536) {
            New-ReviewerCohortEntryRefusal -Code 'CE714' `
                -Detail "The derived model start bound field '$field' is '$value'; the cohort runner reads a 0..65536 integer."
        }
        $maxima[$field] = [int]$parsed
    }
    $declaredSlotCount = [int](Get-ReviewerCohortEntryProperty -Object $bound -Name 'declaredSlotCount' -Where 'derived model start bound' -Code 'CE714')

    # A supplied bound is compared to the derived one statement by statement
    # rather than byte by byte, because the two legitimately name different
    # request paths - an operator derives over the request they hold, this build
    # over the request it just wrote. Everything the cohort runner reads out of
    # the artifact has to agree, and the maxima above all: those are the numbers
    # nothing downstream can second-guess.
    if ($BoundArtifactPath) {
        $expectations = @(
            @('kind', $kind),
            @('requestSha256', $boundRequestSha),
            @('toolkitHead', $boundHead),
            @('declaredSlotCount', $declaredSlotCount),
            @('maxRealModelStarts', [int]$maxima['maxRealModelStarts']),
            @('maxVerifierAssignments', [int]$maxima['maxVerifierAssignments'])
        )
        foreach ($expectation in $expectations) {
            $field = [string]$expectation[0]
            $stated = Get-ReviewerCohortEntryProperty -Object $supplied -Name $field `
                -Where 'pre-derived model start bound' -Code 'CE714'
            if ([string]$stated -cne [string]$expectation[1]) {
                New-ReviewerCohortEntryRefusal -Code 'CE714' `
                    -Detail ("The pre-derived model start bound states $field = '$stated'; this build derives " +
                    "'$($expectation[1])'. A supplied bound is admitted only when it is the bound this build derives.")
            }
        }
    }

    return [pscustomobject][ordered]@{
        MaxRealModelStarts = [int]$maxima['maxRealModelStarts']
        MaxVerifierAssignments = [int]$maxima['maxVerifierAssignments']
        DeclaredSlotCount = $declaredSlotCount
        Sha256 = $derivedSha
    }
}

# ---------------------------------------------------------------------------
# Atomic, read-only, inventoried, authenticated publication
# ---------------------------------------------------------------------------

function Get-ReviewerCohortEntrySealKey {
    <#
    .SYNOPSIS
        The HMAC key the published inventory is authenticated under, in the
        toolkit's own "<format>:<base64>" storage form.
    #>
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        New-ReviewerCohortEntryRefusal -Code 'CE504' -Detail "The seal key '$Path' does not exist."
    }
    $stored = ([IO.File]::ReadAllText($Path)).Trim()
    if (-not $stored.StartsWith('raw:', [StringComparison]::Ordinal)) {
        New-ReviewerCohortEntryRefusal -Code 'CE504' -Detail "The seal key '$Path' is not in the toolkit's '<format>:<base64>' storage form."
    }
    $bytes = $null
    try { $bytes = [Convert]::FromBase64String($stored.Substring(4)) }
    catch { New-ReviewerCohortEntryRefusal -Code 'CE504' -Detail "The seal key '$Path' does not carry canonical base64." }
    if ($bytes.Length -lt 32) {
        New-ReviewerCohortEntryRefusal -Code 'CE504' -Detail "The seal key '$Path' carries $($bytes.Length) bytes; at least 32 are required."
    }
    return [byte[]]$bytes
}

function Get-ReviewerCohortEntryInventory {
    <#
    .SYNOPSIS
        The ordinal inventory of everything under one root: relative path,
        digest and length, in ascending ordinal path order.

    .DESCRIPTION
        A reparse point is refused rather than followed. A published package
        whose "file" is a junction into somewhere else is a package whose bytes
        can change after it was sealed without any of its own bytes changing,
        which is the exact property an immutable evidence root exists to deny.
    #>
    param(
        [Parameter(Mandatory)][string]$Root,
        [string[]]$ExcludeRelativePaths = [string[]]@()
    )
    $fullRoot = [IO.Path]::GetFullPath($Root)
    $files = @(Get-ChildItem -LiteralPath $fullRoot -Recurse -Force -File)
    $records = [System.Collections.Generic.List[object]]::new()
    foreach ($file in $files) {
        if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            New-ReviewerCohortEntryRefusal -Code 'CE505' -Detail "'$($file.FullName)' is a reparse point."
        }
        if (-not (Test-ReviewerCohortEntryPathWithin -Candidate $file.FullName -Root $fullRoot)) {
            New-ReviewerCohortEntryRefusal -Code 'CE506' -Detail "'$($file.FullName)' resolves outside '$fullRoot'."
        }
        $relative = $file.FullName.Substring($fullRoot.Length).TrimStart([IO.Path]::DirectorySeparatorChar).Replace('\', '/')
        if ($ExcludeRelativePaths -ccontains $relative) { continue }
        [void]$records.Add([ordered]@{
                path = $relative
                sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
                length = [int]$file.Length
            })
    }
    $sorted = [object[]]@($records | Sort-Object -Property @{ Expression = { [string]$_.path } } -CaseSensitive)
    return $sorted
}

function Protect-ReviewerCohortEntryRoot {
    <#
    .SYNOPSIS
        Marks every published file read-only, deepest first.
    #>
    param([Parameter(Mandatory)][string]$Root)
    $files = @(Get-ChildItem -LiteralPath $Root -Recurse -Force -File)
    foreach ($file in $files) {
        $file.Attributes = $file.Attributes -bor [IO.FileAttributes]::ReadOnly
    }
}

function Assert-ReviewerCohortEntryPublished {
    <#
    .SYNOPSIS
        Re-verifies a published package from the outside: every inventoried file
        present at the digest and length recorded, read-only, and authenticated
        under the seal key.

    .DESCRIPTION
        Run after the publish rather than trusted from it. The build that wrote
        the package is not evidence that the package is what it says it is; this
        is, and it is the same function an operator runs later to re-verify a
        package they did not watch being built.
    #>
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$SealKeyPath
    )
    $fullRoot = [IO.Path]::GetFullPath($Root)
    # Containment in this package is compared LEXICALLY everywhere else, which a
    # reparse point defeats: a directory junction inside the package resolves to
    # a path outside it while still spelling itself as a child. Rather than
    # resolve every path through the filesystem - which races with anything that
    # can create one - the package is simply required to contain no reparse point
    # at all. It is a build's own output; there is no legitimate reason for one.
    $reparsed = @(Get-ChildItem -LiteralPath $fullRoot -Recurse -Force -Directory -ErrorAction SilentlyContinue |
            Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 })
    if ($reparsed.Count -gt 0) {
        New-ReviewerCohortEntryRefusal -Code 'CE505' `
            -Detail "The package holds $($reparsed.Count) reparse-point director(y|ies), the first at '$($reparsed[0].FullName)'."
    }
    $inventoryPath = Join-Path $fullRoot 'inventory.json'
    $sealPath = Join-Path $fullRoot 'inventory.seal'
    foreach ($path in @($inventoryPath, $sealPath)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            New-ReviewerCohortEntryRefusal -Code 'CE503' -Detail "The package at '$fullRoot' carries no '$(Split-Path $path -Leaf)'."
        }
    }
    $inventoryBytes = [IO.File]::ReadAllBytes($inventoryPath)
    $key = Get-ReviewerCohortEntrySealKey -Path $SealKeyPath
    $hmac = [System.Security.Cryptography.HMACSHA256]::new($key)
    $computed = ''
    try { $computed = [Convert]::ToHexString($hmac.ComputeHash($inventoryBytes)).ToLowerInvariant() }
    finally { $hmac.Dispose() }
    $recorded = ([IO.File]::ReadAllText($sealPath)).Trim()
    if ($computed -cne $recorded) {
        New-ReviewerCohortEntryRefusal -Code 'CE503' -Detail "The inventory seal at '$fullRoot' does not authenticate the inventory."
    }
    $inventory = $script:ReviewerCohortEntryUtf8.GetString($inventoryBytes) | ConvertFrom-Json -Depth 32
    $declared = @($inventory.files)
    $declaredPaths = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($record in $declared) {
        $relative = [string]$record.path
        # The inventory is data, and data from a package this function is being
        # asked to distrust. A recorded path is therefore checked for shape
        # BEFORE it is joined onto the root, so a doctored inventory cannot walk
        # the verifier out of the package and have it authenticate a file that
        # lives somewhere else entirely.
        if ($relative -cmatch '^[A-Za-z]:' -or $relative.StartsWith('/') -or $relative.Contains('\') -or
            @($relative -split '/') -ccontains '..') {
            New-ReviewerCohortEntryRefusal -Code 'CE506' -Detail "The inventory names '$relative', which is not a plain relative path inside the package."
        }
        if (-not $declaredPaths.Add($relative)) {
            New-ReviewerCohortEntryRefusal -Code 'CE503' -Detail "The inventory names '$relative' more than once."
        }
        $full = $fullRoot
        $segments = [string[]]@($relative -split '/')
        foreach ($segment in $segments) { $full = Join-Path $full $segment }
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
            New-ReviewerCohortEntryRefusal -Code 'CE503' -Detail "The inventory names '$relative', which is not on disk."
        }
        # Constructed rather than fetched with Get-Item, so what follows reads a
        # file's own attributes and length instead of counting whatever a command
        # happened to return.
        $item = [IO.FileInfo]::new($full)
        if (($item.Attributes -band [IO.FileAttributes]::ReadOnly) -eq 0) {
            New-ReviewerCohortEntryRefusal -Code 'CE502' -Detail "'$relative' is writable."
        }
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            New-ReviewerCohortEntryRefusal -Code 'CE505' -Detail "'$relative' is a reparse point."
        }
        $sha = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($sha -cne [string]$record.sha256) {
            New-ReviewerCohortEntryRefusal -Code 'CE503' -Detail "'$relative' hashes to $sha and the inventory records $([string]$record.sha256)."
        }
        if ([int]$item.Length -ne [int]$record.length) {
            New-ReviewerCohortEntryRefusal -Code 'CE503' -Detail "'$relative' is $([int]$item.Length) bytes and the inventory records $([int]$record.length)."
        }
    }
    # The inventory cannot inventory itself, so its own two files are checked
    # here. Without this an operator could leave the seal writable and re-seal a
    # package they had edited, and every other check above would still pass.
    foreach ($selfPath in @($inventoryPath, $sealPath)) {
        $selfItem = [IO.FileInfo]::new($selfPath)
        if (($selfItem.Attributes -band [IO.FileAttributes]::ReadOnly) -eq 0) {
            New-ReviewerCohortEntryRefusal -Code 'CE502' -Detail "'$(Split-Path $selfPath -Leaf)' is writable."
        }
    }
    # Compared as SETS, not as counts. Equal counts with different membership is
    # exactly the shape of a substitution - one inventoried file removed and one
    # unlisted file added - and a count check calls that package intact.
    $onDisk = @(Get-ReviewerCohortEntryInventory -Root $fullRoot -ExcludeRelativePaths @('inventory.json', 'inventory.seal'))
    $onDiskPaths = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($found in $onDisk) { [void]$onDiskPaths.Add([string]$found.path) }
    $extra = @($onDiskPaths | Where-Object { -not $declaredPaths.Contains($_) } | Sort-Object)
    if ($extra.Count -gt 0) {
        New-ReviewerCohortEntryRefusal -Code 'CE503' `
            -Detail "The package holds $($extra.Count) file(s) the inventory does not declare: $($extra -join ', ')."
    }
    $missing = @($declaredPaths | Where-Object { -not $onDiskPaths.Contains($_) } | Sort-Object)
    if ($missing.Count -gt 0) {
        New-ReviewerCohortEntryRefusal -Code 'CE503' `
            -Detail "The inventory declares $($missing.Count) file(s) the package does not hold: $($missing -join ', ')."
    }
    return $true
}

function Publish-ReviewerCohortEntryPackage {
    <#
    .SYNOPSIS
        Moves a fully built staging root into its final place in one filesystem
        operation, then inventories, seals, freezes and re-verifies it.

    .DESCRIPTION
        The staging root is a sibling of the destination so the move is a rename
        rather than a copy: a build killed at any moment either leaves a staging
        directory nobody reads or a complete package, and never a destination
        half-populated with evidence that looks whole.
    #>
    param(
        [Parameter(Mandatory)][string]$StagingRoot,
        [Parameter(Mandatory)][string]$DestinationRoot,
        [Parameter(Mandatory)][string]$SealKeyPath
    )
    $destination = [IO.Path]::GetFullPath($DestinationRoot)
    if (Test-Path -LiteralPath $destination) {
        $existing = @(Get-ChildItem -LiteralPath $destination -Force)
        if ($existing.Count -gt 0) {
            New-ReviewerCohortEntryRefusal -Code 'CE500' -Detail "'$destination' already holds $($existing.Count) item(s)."
        }
        Remove-Item -LiteralPath $destination -Force -Recurse
    }

    $files = @(Get-ReviewerCohortEntryInventory -Root $StagingRoot)
    $inventory = [ordered]@{
        kind = 'devpilot.shadow-cohort.entry-evidence-inventory.v1'
        fileCount = $files.Count
        files = [object[]]$files
    }
    $inventoryPath = Join-Path $StagingRoot 'inventory.json'
    [IO.File]::WriteAllBytes($inventoryPath,
        $script:ReviewerCohortEntryUtf8.GetBytes((ConvertTo-AgentReplayCanonicalJson -Value $inventory)))
    $key = Get-ReviewerCohortEntrySealKey -Path $SealKeyPath
    $hmac = [System.Security.Cryptography.HMACSHA256]::new($key)
    $seal = ''
    try { $seal = [Convert]::ToHexString($hmac.ComputeHash([IO.File]::ReadAllBytes($inventoryPath))).ToLowerInvariant() }
    finally { $hmac.Dispose() }
    [IO.File]::WriteAllBytes((Join-Path $StagingRoot 'inventory.seal'),
        $script:ReviewerCohortEntryUtf8.GetBytes($seal))

    # Frozen BEFORE the rename, not after. Moving first and freezing second
    # leaves a window in which the destination exists, looks complete and is
    # writable - and a reader or a crash landing inside that window sees a
    # published package it could still modify. A rename cannot be interrupted
    # half-way, so freezing first makes "published" and "read-only" the same
    # instant. The destination is re-frozen after the move anyway, because a
    # move across a volume boundary is a copy and need not carry attributes.
    Protect-ReviewerCohortEntryRoot -Root $StagingRoot

    $parent = Split-Path -Parent $destination
    if ($parent -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
        [void](New-Item -ItemType Directory -Force -Path $parent)
    }
    try { [IO.Directory]::Move($StagingRoot, $destination) }
    catch {
        New-ReviewerCohortEntryRefusal -Code 'CE501' -Detail "The staging root could not be moved into '$destination': $($_.Exception.Message)"
    }
    Protect-ReviewerCohortEntryRoot -Root $destination
    [void](Assert-ReviewerCohortEntryPublished -Root $destination -SealKeyPath $SealKeyPath)
    return $destination
}
