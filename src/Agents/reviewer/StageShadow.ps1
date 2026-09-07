#!/usr/bin/env pwsh
<#
.SYNOPSIS
    The opt-in shadow switch that puts the on-disk half of the stage file
    contract in force, without changing a single semantic decision.

.DESCRIPTION
    StageContract.ps1 says how a stage contract is judged and how it is written
    and read. StageProducers.ps1 says which twelve boundaries exist. Neither of
    them, on its own, ever puts a versioned envelope on disk on a live run - so
    until this file existed no consumer had seen a `kind` or a `contractVersion`
    come off disk, and the escape ledger recorded the on-disk half as not in
    force for exactly that reason.

    This is the switch that closes it. When it is enabled, every one of the
    twelve shipping producer boundaries publishes its judged payload through
    Write-ReviewerStageArtifact and immediately reads it back through
    Read-ReviewerStageArtifact before the payload goes anywhere downstream. The
    reread is not a formality: the contract version the FILE declares, its bytes,
    its declared serialization form and depth, and its full payload are compared
    against what was written, and a disagreement throws. The kind the file
    declares is compared too, but counted as redundancy rather than evidence -
    the strict reader already refuses a kind mismatch itself, so that one clause
    cannot fire with the shipped reader. A run with the switch on therefore
    cannot reach a downstream stage with a payload that did not survive a real
    file round trip.

    Three properties make this safe to ship:

      * DEFAULT-OFF. With the switch disabled - which is every ordinary run -
        Publish-ReviewerStageShadowArtifact returns its input unchanged and
        touches no filesystem. Every payload it returns and every filesystem
        effect it has are unchanged from before this file existed.

      * NO SEMANTIC CHANGE. What flows downstream is the in-memory payload the
        boundary already judged, never a JSON reconstruction of it. The reread
        payload is used as EVIDENCE - it must serialize identically to the
        payload that was written, or the run fails - rather than as a
        replacement, so no decision downstream is ever taken on a parsed value.

        Be precise about what that does and does not prove. It proves the
        payload is SERIALIZABLE and rereadable: it survives write, strict read,
        contract judgement and reserialization with identical text and bytes. It
        does NOT prove the reconstruction is SUBSTITUTABLE for the original,
        because the comparison is between two serializations and a serialization
        is lossy about CLR types. ConvertFrom-Json reconstructs an integral JSON
        number within the Int64 range as Int64, so Int32 and every narrower
        integer type comes back widened, and one outside that range comes back as
        a BigInteger; a non-integral one may come back as Double, so a Decimal
        loses its type; a DateTimeOffset comes back as a string or a DateTime;
        and a Double that is NaN or Infinity is written as a string and returns
        as one. Nothing
        downstream consumes the reconstruction, so that gap cannot change a
        decision here; it is a real limit on what a future consumer that DOES
        read these files off disk may assume, and it is recorded as such.

      * NO EXTERNAL DELIVERY WRITES. This switch writes files - that is its whole
        purpose - but only private state under a directory it owns. It refuses to
        enable while any delivery capability
        is live, and it recomputes that through the same authority the delivery
        path uses (Get-ReviewerGateWritesCurrentlyRequested) rather than
        accepting a caller's verdict. Artifacts land only under a directory this
        switch designated by its caller and marked by convention. Each is made
        read-only when published - an advisory
        attribute that deters an accidental edit rather than enforcing
        immutability - and a publication that would overwrite an existing
        artifact is refused outright.
#>

Set-StrictMode -Version Latest

if (-not (Get-Variable -Name 'ReviewerStageContractRegistry' -Scope Script -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'StageContract.ps1')
}

# The marker by which this switch recognises a directory it has used before. A
# directory holding anything else is refused rather than adopted, so the switch
# does not publish private state into a populated tree by accident. The marker is
# a convention, not a title: the directory is caller-designated and
# convention-marked, and anything with write access could forge the marker.
$script:ReviewerStageShadowMarkerName = '.reviewer-stage-shadow.json'
$script:ReviewerStageShadowMarkerVersion = 1
$script:ReviewerStageShadowDefaultDepth = 48
# The stage reader's declared-depth ceiling, not ConvertTo-Json's - that one is
# 100, and a serialization deeper than 64 is perfectly possible. The cap is a
# contract limit, not a serializer limit: the probe is capped at the reader's 64,
# and publication is capped at 56 so eight probe levels are always in reserve.
$script:ReviewerStageShadowProbeCeiling = 64
$script:ReviewerStageShadowMaxPublishDepth = 56
# Bounded for the same reason the contract ledger is: the reviewer is a
# long-lived loop and every boundary crossing appends here.
$script:ReviewerStageShadowMaxRecords = 4096
$script:ReviewerStageShadowState = $null
$script:ReviewerStageShadowRecords = [System.Collections.Generic.List[object]]::new()
$script:ReviewerStageShadowSequence = 0

function Test-ReviewerStageShadowContractEnabled {
    <#
    .SYNOPSIS
        Whether the on-disk half of the stage contract is currently in force.
    #>
    return ($null -ne $script:ReviewerStageShadowState)
}

function Get-ReviewerStageShadowContractState {
    <#
    .SYNOPSIS
        The active shadow session, or a refusal. Never a null a caller could
        mistake for "disabled but fine".
    #>
    if ($null -eq $script:ReviewerStageShadowState) {
        throw 'The reviewer stage shadow contract is not enabled.'
    }
    return $script:ReviewerStageShadowState
}

function Get-ReviewerStageShadowWriteCapability {
    <#
    .SYNOPSIS
        What layer 6 may attempt right now, from the one authority that decides
        it.

    .DESCRIPTION
        This deliberately does NOT accept a pre-computed verdict. The caller
        hands over the raw switches and the effective policy object and the
        answer is recomputed here through the delivery gate's own predicate, so
        a caller cannot open the switch by asserting "nothing can be written";
        it has to present inputs the gate itself agrees are write-free. If the
        delivery authority is not loaded, the question cannot be asked and the
        switch refuses - fail closed, because "the check was unavailable" and
        "the check passed" must never be the same outcome.

        Residual, stated plainly rather than papered over: the policy object is
        still supplied by the caller, so this is a constraint on the caller's
        declared configuration, not an independent observation of a live run's
        policy. It is the outermost refusal, not the only one - the offline
        run tools additionally assert zero provider calls and zero external
        writes after the fact.
    #>
    param(
        [Parameter(Mandatory)]$EffectivePolicy,
        [Parameter(Mandatory)][bool]$CommentSwitchOn,
        [Parameter(Mandatory)][bool]$SuggestionSwitchOn,
        [Parameter(Mandatory)][bool]$ApprovalSwitchOn
    )

    $authority = Get-Command -Name 'Get-ReviewerGateWritesCurrentlyRequested' -CommandType Function -ErrorAction SilentlyContinue
    if ($null -eq $authority) {
        throw 'The reviewer stage shadow contract cannot be enabled without the delivery write authority (Get-ReviewerGateWritesCurrentlyRequested) loaded; a shadow run that cannot ask whether writes are live must not start.'
    }
    return & $authority -EffectivePolicy $EffectivePolicy `
        -CommentSwitchOn $CommentSwitchOn `
        -SuggestionSwitchOn $SuggestionSwitchOn `
        -ApprovalSwitchOn $ApprovalSwitchOn
}

function Assert-ReviewerStageShadowNoWriteCapability {
    <#
    .SYNOPSIS
        Refuses the switch while any delivery capability is live.

    .DESCRIPTION
        Every capability the authority reports is checked, including one it
        might grow later: an unknown property that is true is a refusal, not a
        tolerated extra, so adding a fourth way to write cannot silently become
        a way to write during a shadow run.
    #>
    param([Parameter(Mandatory)][AllowNull()]$WriteCapability)

    if ($null -eq $WriteCapability) {
        throw 'The reviewer stage shadow contract refused to enable: the delivery write authority returned nothing.'
    }
    $required = [string[]]@('Comments', 'Suggestions', 'Approval')
    $properties = @($WriteCapability.PSObject.Properties)
    $names = [string[]]@($properties | ForEach-Object { [string]$_.Name })
    $missing = @($required | Where-Object { $names -cnotcontains $_ })
    if ($missing.Count -gt 0) {
        throw "The reviewer stage shadow contract refused to enable: the delivery write authority did not report capability $($missing -join ', ')."
    }
    $live = [System.Collections.Generic.List[string]]::new()
    foreach ($property in $properties) {
        if ($property.Value -isnot [bool]) {
            throw "The reviewer stage shadow contract refused to enable: delivery capability '$($property.Name)' is not a boolean."
        }
        if ([bool]$property.Value) { [void]$live.Add([string]$property.Name) }
    }
    if ($live.Count -gt 0) {
        throw "The reviewer stage shadow contract refused to enable: delivery capability $($live -join ', ') is enabled. A shadow run publishes stage contracts to private state and must not coexist with any external write."
    }
}

function Assert-ReviewerStageShadowPrivateDirectory {
    <#
    .SYNOPSIS
        Checks a directory is one this switch may publish into.

    .DESCRIPTION
        An empty directory is adopted and marked. A directory already carrying
        this switch's marker is reused. Anything else - a directory holding a
        file this switch did not write - is refused, because publishing private
        run state into somebody else's tree is how private state stops being
        private.

        The marker is a convention, not proof of ownership: anything that can
        write to the directory can write the marker, so this refuses the accident
        (a caller pointing the switch at a populated tree) rather than an
        adversary who wants the switch to adopt a directory.
    #>
    param([Parameter(Mandatory)][string]$Directory)

    if ([string]::IsNullOrWhiteSpace($Directory)) {
        throw 'The reviewer stage shadow contract needs a directory to publish into.'
    }
    if (Test-Path -LiteralPath $Directory -PathType Leaf) {
        throw "The reviewer stage shadow directory '$Directory' is a file."
    }
    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
        New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    }
    $resolved = (Resolve-Path -LiteralPath $Directory).ProviderPath
    $markerPath = Join-Path $resolved $script:ReviewerStageShadowMarkerName
    $existing = @(Get-ChildItem -LiteralPath $resolved -Force |
            Where-Object { [string]$_.Name -cne $script:ReviewerStageShadowMarkerName })
    if ($existing.Count -gt 0 -and -not (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
        throw "The reviewer stage shadow directory '$resolved' already holds $($existing.Count) item(s) this switch did not write; refusing to adopt it as private state."
    }
    return $resolved
}

function Enable-ReviewerStageShadowContract {
    <#
    .SYNOPSIS
        Turns the on-disk half of the stage file contract on for this process.

    .DESCRIPTION
        Opt-in and process-scoped. The caller states where private state may go
        and hands over the raw delivery switches and effective policy; this
        function recomputes what those mean through the delivery authority's own
        predicate rather than accepting a verdict, and refuses if the answer is
        that anything can be written.
    #>
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)]$EffectivePolicy,
        [Parameter(Mandatory)][bool]$CommentSwitchOn,
        [Parameter(Mandatory)][bool]$SuggestionSwitchOn,
        [Parameter(Mandatory)][bool]$ApprovalSwitchOn,
        [string]$Reason = 'stage-contract-shadow',
        [ValidateRange(2, 56)][int]$Depth = $script:ReviewerStageShadowDefaultDepth,
        [ValidateSet('compact', 'indented')][string]$Form = 'compact'
    )

    if ($null -ne $script:ReviewerStageShadowState) {
        throw 'The reviewer stage shadow contract is already enabled; disable it before enabling it again.'
    }
    $capability = Get-ReviewerStageShadowWriteCapability -EffectivePolicy $EffectivePolicy `
        -CommentSwitchOn $CommentSwitchOn -SuggestionSwitchOn $SuggestionSwitchOn `
        -ApprovalSwitchOn $ApprovalSwitchOn
    Assert-ReviewerStageShadowNoWriteCapability -WriteCapability $capability
    $resolved = Assert-ReviewerStageShadowPrivateDirectory -Directory $Directory

    $sessionId = [Guid]::NewGuid().ToString('N')
    # A marked directory may legitimately be reused, but the artifacts already in
    # it are published evidence. The sequence therefore continues past whatever is
    # there rather than restarting at one, so a second session cannot land on a
    # name the first one already used.
    #
    # Reserved names count too, not just published ones. A publish that reserves a
    # name and then refuses the payload leaves a sidecar and no artifact; if the
    # seed only looked at artifacts, the next session would land on that burned
    # number and be refused forever over evidence that does not exist. Seeding past
    # both keeps the collision refusal meaning a live collision and nothing else.
    $highest = 0
    foreach ($existing in (Get-ChildItem -LiteralPath $resolved -File -ErrorAction SilentlyContinue)) {
        if ([string]$existing.Name -notlike '*.stage.json' -and
            [string]$existing.Name -notlike '*.stage.json.reservation') {
            continue
        }
        if ([string]$existing.Name -match '^(?<seq>\d{5})-') {
            $observed = [int]$Matches['seq']
            if ($observed -gt $highest) { $highest = $observed }
        }
    }
    if ($highest -gt $script:ReviewerStageShadowSequence) {
        $script:ReviewerStageShadowSequence = $highest
    }
    $state = [pscustomobject][ordered]@{
        Directory = $resolved
        SessionId = $sessionId
        Reason = $Reason
        Depth = $Depth
        Form = $Form
    }
    $marker = [ordered]@{
        markerVersion = $script:ReviewerStageShadowMarkerVersion
        kind = 'reviewer.stage.shadow.session'
        sessionId = $sessionId
        reason = $Reason
        depth = $Depth
        form = $Form
        writeCapability = [ordered]@{
            comments = [bool]$capability.Comments
            suggestions = [bool]$capability.Suggestions
            approval = [bool]$capability.Approval
        }
    }
    $utf8 = [System.Text.UTF8Encoding]::new($false, $true)
    [IO.File]::WriteAllBytes((Join-Path $resolved $script:ReviewerStageShadowMarkerName),
        $utf8.GetBytes((ConvertTo-Json -InputObject $marker -Depth 8 -Compress) + "`n"))

    $script:ReviewerStageShadowState = $state
    return $state
}

function Disable-ReviewerStageShadowContract {
    <#
    .SYNOPSIS
        Turns the switch back off. Published artifacts are left where they are:
        they are the evidence the run happened.
    #>
    $script:ReviewerStageShadowState = $null
}

function Clear-ReviewerStageShadowContractLedger {
    $script:ReviewerStageShadowRecords = [System.Collections.Generic.List[object]]::new()
    $script:ReviewerStageShadowSequence = 0
}

function Get-ReviewerStageShadowContractLedger {
    <#
    .SYNOPSIS
        Every artifact this switch published and read back, in publication
        order, as a real collection at zero, one, and many entries.
    #>
    Write-Output -NoEnumerate ([object[]]$script:ReviewerStageShadowRecords.ToArray())
}

function ConvertTo-ReviewerStageShadowComparable {
    <#
    .SYNOPSIS
        The serialization of a payload at a stated depth, for comparing what
        was written against what came back.

    .DESCRIPTION
        Deliberately the same serializer the writer uses, at the same depth: the
        question this answers is "did the file round trip preserve the payload",
        and answering it with a different serializer would compare two things
        neither of which is on disk.
    #>
    param(
        [Parameter(Mandatory)][AllowNull()]$Value,
        [Parameter(Mandatory)][ValidateRange(2, 64)][int]$Depth
    )

    # The depth warning is suppressed on purpose: it is a host-stream side effect
    # that would contaminate a caller's stdout, and truncation is detected here
    # by comparing against a strictly deeper serialization rather than by hoping
    # somebody read a warning.
    return [string](ConvertTo-Json -InputObject $Value -Depth $Depth -Compress -WarningAction SilentlyContinue)
}

function Assert-ReviewerStageShadowDepthSufficient {
    <#
    .SYNOPSIS
        Refuses a payload that is deeper than the depth it is being written at.

    .DESCRIPTION
        ConvertTo-Json past its depth does not fail; it replaces the too-deep
        subtree with a type name and carries on. Both sides of a round-trip
        comparison would truncate identically, so the comparison alone cannot
        see it. Serializing once more at a strictly greater depth can: if the
        two differ, the shallower one lost something.
    #>
    param(
        [Parameter(Mandatory)][AllowNull()]$Payload,
        [Parameter(Mandatory)][ValidateRange(2, 64)][int]$Depth,
        [Parameter(Mandatory)][string]$Kind
    )

    if ($Depth -ge $script:ReviewerStageShadowProbeCeiling) {
        # No deeper probe is available WITHIN the contract's declared-depth range.
    # ConvertTo-Json itself would go to 100; the comparable helper is bounded to
    # the same 2..64 the stage contract declares, so at 64 there is nothing left
    # to compare against and truncation cannot be ruled out here.
        # Refusing is the only honest answer; the enable path keeps the caller
        # below this ceiling so it is unreachable in practice.
        throw "Stage contract '$Kind' would be published at depth $Depth, which leaves no deeper probe inside the stage contract's declared-depth range to rule out silent truncation."
    }
    $probeDepth = [Math]::Min($script:ReviewerStageShadowProbeCeiling, $Depth + 8)
    $atDepth = ConvertTo-ReviewerStageShadowComparable -Value $Payload -Depth $Depth
    $atProbe = ConvertTo-ReviewerStageShadowComparable -Value $Payload -Depth $probeDepth
    if ($atDepth -cne $atProbe) {
        throw "Stage contract '$Kind' is deeper than the depth $Depth it would be published at; the artifact would be silently truncated."
    }
}

function Publish-ReviewerStageShadowArtifact {
    <#
    .SYNOPSIS
        Publishes one judged stage payload as a versioned artifact and reads it
        back before the payload is used downstream.

    .DESCRIPTION
        With the switch off this is the identity function and touches nothing,
        which is what keeps default production behaviour unchanged.

        With the switch on it writes the envelope through the shared atomic
        UTF-8-no-BOM writer under -StrictShape, makes the file read-only, and
        reads it back through the strict reader. The reread verdict is then
        CONSUMED, and only on values that actually came off disk: the contract
        version the FILE declared, whether an adapter was needed, the byte digest
        and length, the declared form and depth, and the full serialized payload
        all have to agree with what was written, or the boundary throws and the
        stage never proceeds. The reader's registry-held kind and version are
        deliberately not compared, because those are what the reader was asked
        for and cannot disagree with themselves.

        The kind clause is the one exception, and it is honest about being
        redundant. SourceKind is genuinely off-disk - the reader lifts it from
        the envelope before any adaptation - but Read-ReviewerStageArtifact
        already refuses a kind mismatch itself, so with the shipped reader that
        comparison cannot fail. It stays as a second line against a future reader
        that stops refusing, not as evidence that anything was checked here.

        The value handed back is the in-memory payload, not the reconstruction.
        That is the whole reason this is safe to ship: the round trip is proven
        on every crossing, but no decision downstream is ever taken on a value
        that came from a JSON parser.
    #>
    param(
        [Parameter(Mandatory)][string]$Stage,
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)][AllowNull()]$Payload,
        [Parameter(Mandatory)][string]$Producer
    )

    if ($null -eq $script:ReviewerStageShadowState) { return $Payload }

    $state = $script:ReviewerStageShadowState
    $depth = [int]$state.Depth
    Assert-ReviewerStageShadowDepthSufficient -Payload $Payload -Depth $depth -Kind $Kind

    $script:ReviewerStageShadowSequence++
    $sequence = $script:ReviewerStageShadowSequence
    $name = '{0:d5}-{1}.stage.json' -f $sequence, $Stage
    $path = Join-Path ([string]$state.Directory) $name
    # The read-only attribute set below deters an accidental edit; it does not
    # stop the atomic writer, whose Move-Item -Force would happily replace a
    # read-only file. Refusing the collision here is the part that actually
    # prevents a later publication from erasing an earlier one - and the refusal
    # is an atomic CreateNew reservation rather than a Test-Path look, because a
    # look-then-write leaves a window in which two publishers both see nothing
    # and the second one's Move-Item -Force erases the first one's evidence.
    # CreateNew cannot both succeed; the loser throws here instead of winning.
    #
    # The reservation is a SIDECAR, never the artifact path itself. Reserving the
    # artifact path would publish a visible zero-byte file for as long as the
    # write takes, and a concurrent reader would see an empty artifact. The
    # sidecar is deliberately not removed afterwards: it is the tombstone that
    # makes the name unusable again, so deleting it would reopen the collision.
    $reservationPath = $path + '.reservation'
    try {
        $reservation = [System.IO.File]::Open(
            $reservationPath,
            [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None)
        $reservation.Dispose()
    }
    catch [System.IO.IOException] {
        throw "Stage contract '$Kind' producer '$Producer' would overwrite published evidence at '$path'."
    }

    $written = Write-ReviewerStageArtifact -Path $path -Kind $Kind -Payload $Payload `
        -Depth $depth -Form ([string]$state.Form) -StrictShape
    # Made read-only the moment it exists, to deter an accidental edit. This is
    # an advisory attribute, not enforcement: anything holding the path can clear
    # it. The collision refusal above is what carries the real weight.
    $item = Get-Item -LiteralPath $path
    $item.IsReadOnly = $true

    $read = Read-ReviewerStageArtifact -Path $path -Kind $Kind
    if ($null -eq $read) {
        throw "Stage contract '$Kind' producer '$Producer' published '$path' but read nothing back."
    }
    # Redundant with the reader's own kind refusal and known to be: with the
    # shipped Read-ReviewerStageArtifact this cannot fire. Kept as a second line
    # against a future reader that stops refusing, not counted as evidence.
    if ([string]$read.SourceKind -cne [string]$Kind) {
        throw "Stage contract '$Kind' producer '$Producer' read back kind '$($read.SourceKind)' from '$path'."
    }
    if ([int]$read.SourceVersion -ne [int]$written.ContractVersion -or [bool]$read.Adapted) {
        throw "Stage contract '$Kind' producer '$Producer' needed a version adapter to read back what it just wrote at '$path'."
    }
    if ([string]$read.Sha256 -cne [string]$written.Sha256 -or
        [int]$read.ByteLength -ne [int]$written.ByteLength) {
        throw "Stage contract '$Kind' producer '$Producer' read back different bytes than it wrote at '$path'."
    }
    if ([string]$read.Form -cne [string]$written.Form -or [int]$read.Depth -ne [int]$written.Depth) {
        throw "Stage contract '$Kind' producer '$Producer' read back a different serialization decision from '$path'."
    }
    # Both sides are put through the writer's own key ordering before they are
    # compared. The expected side is still the in-memory payload with its
    # unordered dictionaries, and the actual side is already in file order, so
    # without this the check would report a round-trip loss for a payload that
    # round-tripped perfectly and merely got its keys written down in the one
    # order two processes can agree on.
    $expected = ConvertTo-ReviewerStageShadowComparable `
        -Value (ConvertTo-ReviewerStageDeterministicKeyOrder -Node $Payload) -Depth $depth
    $actual = ConvertTo-ReviewerStageShadowComparable `
        -Value (ConvertTo-ReviewerStageDeterministicKeyOrder -Node $read.Payload) -Depth $depth
    if ($expected -cne $actual) {
        throw "Stage contract '$Kind' producer '$Producer' did not survive its own file round trip at '$path'."
    }

    $contract = Get-ReviewerStageContract -Kind $Kind
    $record = [pscustomobject][ordered]@{
        Sequence = $sequence
        Stage = $Stage
        Kind = [string]$written.Kind
        ContractVersion = [int]$written.ContractVersion
        Producer = $Producer
        Path = $path
        Name = $name
        Form = [string]$written.Form
        Depth = [int]$written.Depth
        ByteLength = [int]$written.ByteLength
        Sha256 = [string]$written.Sha256
        ReadOnly = [bool](Get-Item -LiteralPath $path).IsReadOnly
        ObservedCounts = Measure-ReviewerStageFieldCardinality -Payload $read.Payload `
            -CollectionFields $contract.CollectionFields
    }
    [void]$script:ReviewerStageShadowRecords.Add($record)
    $overflow = $script:ReviewerStageShadowRecords.Count - $script:ReviewerStageShadowMaxRecords
    if ($overflow -gt 0) { $script:ReviewerStageShadowRecords.RemoveRange(0, $overflow) }

    # The in-memory payload, proven equal to what a strict reader got off disk.
    return $Payload
}
