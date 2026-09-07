#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Versioned file contract for reviewer stage child outputs.

.DESCRIPTION
    Every stage that hands structured output to a later stage writes it through
    Write-ReviewerStageArtifact and reads it through Read-ReviewerStageArtifact.
    The contract is deliberately narrow and fail-closed:

      * the payload is wrapped in an envelope that states contractVersion and
        kind, so a reader never has to infer what it is holding;
      * bytes are UTF-8 with no BOM, written to a file the CALLER named - a
        stage never publishes its contract on stdout, where a stray Write-Host
        or a progress record would corrupt it;
      * the serialization depth and the compact/indented form are stated
        explicitly by the writer and recorded in the envelope, so a reader can
        prove the on-disk form is the one the writer intended rather than a
        host default that silently truncated nested collections;
      * declared collection fields are materialized as JSON arrays on write and
        required to still be arrays on read, which is what stops a zero- or
        one-element collection collapsing to null or to a scalar as it crosses
        the file boundary;
      * unknown fields and missing required fields are rejected as policy, not
        tolerated, so a contract change cannot half-land; and
      * truncated, empty, scalar-collapsed, and stdout-contaminated payloads all
        fail closed rather than parse into a plausible-looking partial value.

    Existing artifacts are not broken silently. A contract declares every
    version it supports, and reading an older version requires an explicit
    registered adapter; without one, the read fails rather than guessing.
#>

Set-StrictMode -Version Latest

# Encoder for every contract byte: UTF-8, no BOM, and strict on invalid
# sequences so a mis-encoded payload fails at the boundary instead of being
# silently replaced with U+FFFD.
$script:ReviewerStageContractUtf8 = [System.Text.UTF8Encoding]::new($false, $true)
$script:ReviewerStageContractEnvelopeVersion = 1
$script:ReviewerStageContractEnvelopeFields = @(
    'envelopeVersion', 'kind', 'contractVersion', 'form', 'depth', 'payload')
$script:ReviewerStageContractForms = @('compact', 'indented')
$script:ReviewerStageContractMaxBytes = 33554432
$script:ReviewerStageContractRegistry =
[System.Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
# Every Assert/Write/Read that judged a contract is recorded here, in call order.
# The ledger is what makes adoption observable: a stage that stops calling the
# boundary stops appearing, and a test can say so by name instead of waiting for
# a downstream symptom.
#
# It is bounded. The reviewer agent is a single process that loops on an interval
# for as long as it is left running, and every boundary crossing appends here, so
# an uncapped list is a slow leak that no -Once test run can observe. The cap
# keeps the most recent entries, which is what every reader of this ledger wants:
# adoption is a claim about the run that just happened. Sequence numbers are
# monotonic across evictions so a reader can still tell a trimmed ledger from a
# short one.
$script:ReviewerStageContractLedgerMaxEntries = 4096
$script:ReviewerStageContractLedgerSequence = 0
$script:ReviewerStageContractLedger = [System.Collections.Generic.List[object]]::new()

function Register-ReviewerStageContract {
    <#
    .SYNOPSIS
        Declares one stage contract: its current version, the versions it can
        still read, its required and optional payload fields, the fields that
        must remain collections, and any explicit version adapters.
    #>
    param(
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)][ValidateRange(1, 1000)][int]$ContractVersion,
        [string[]]$RequiredFields = @(),
        [string[]]$OptionalFields = @(),
        [string[]]$CollectionFields = @(),
        [string[]]$MapFields = @(),
        [int[]]$SupportedVersions = @(),
        [System.Collections.IDictionary]$Adapters = $null
    )

    if ($Kind -notmatch '^[a-z][a-z0-9]*(\.[a-z0-9-]+)+$') {
        throw "Stage contract kind '$Kind' is not a dotted lowercase contract name."
    }
    $supported = [int[]]@($SupportedVersions)
    if ($supported.Count -eq 0) { $supported = [int[]]@($ContractVersion) }
    if ($supported -notcontains $ContractVersion) {
        throw "Stage contract '$Kind' does not list its own current version $ContractVersion as supported."
    }
    $required = [string[]]@($RequiredFields)
    $optional = [string[]]@($OptionalFields)
    $overlap = @($required | Where-Object { $optional -contains $_ })
    if ($overlap.Count -gt 0) {
        throw "Stage contract '$Kind' declares '$($overlap -join ", ")' as both required and optional."
    }
    $collections = [string[]]@($CollectionFields)
    $maps = [string[]]@($MapFields)
    # A field is either a list or a keyed map. Declaring both would ask the
    # normalizer to rewrite the same site into two incompatible shapes, and the
    # last writer would silently win.
    $shapeOverlap = @($collections | Where-Object { $maps -contains $_ })
    if ($shapeOverlap.Count -gt 0) {
        throw "Stage contract '$Kind' declares '$($shapeOverlap -join ", ")' as both a collection and a map."
    }
    # A hashtable, not an ordered dictionary: an OrderedDictionary indexed by an
    # integer resolves the positional overload, so integer version keys would
    # address slots instead of versions.
    $adapterTable = @{}
    if ($null -ne $Adapters) {
        foreach ($key in (ConvertTo-ReviewerStageArray -Value $Adapters.Keys)) {
            $fromVersion = [int]$key
            if ($fromVersion -eq $ContractVersion) {
                throw "Stage contract '$Kind' registers an adapter from its own current version."
            }
            if ($supported -notcontains $fromVersion) {
                throw "Stage contract '$Kind' registers an adapter from unsupported version $fromVersion."
            }
            if ($Adapters[$key] -isnot [scriptblock]) {
                throw "Stage contract '$Kind' adapter for version $fromVersion is not a script block."
            }
            $adapterTable[$fromVersion] = $Adapters[$key]
        }
    }
    foreach ($version in $supported) {
        if ($version -eq $ContractVersion) { continue }
        if (-not $adapterTable.Contains($version)) {
            throw "Stage contract '$Kind' supports version $version without an explicit adapter."
        }
    }

    $script:ReviewerStageContractRegistry[$Kind] = [pscustomobject][ordered]@{
        Kind = $Kind
        ContractVersion = $ContractVersion
        SupportedVersions = $supported
        RequiredFields = $required
        OptionalFields = $optional
        CollectionFields = $collections
        MapFields = $maps
        Adapters = $adapterTable
    }
    return $script:ReviewerStageContractRegistry[$Kind]
}

function Get-ReviewerStageContract {
    param([Parameter(Mandatory)][string]$Kind)

    if (-not $script:ReviewerStageContractRegistry.Contains($Kind)) {
        throw "Stage contract '$Kind' is not registered."
    }
    return $script:ReviewerStageContractRegistry[$Kind]
}

function Get-ReviewerStageContractKind {
    $kinds = [System.Collections.Generic.List[string]]::new()
    foreach ($key in (ConvertTo-ReviewerStageArray -Value $script:ReviewerStageContractRegistry.Keys)) { [void]$kinds.Add([string]$key) }
    Write-Output -NoEnumerate ([string[]]$kinds.ToArray())
}

function Clear-ReviewerStageContractRegistry {
    $script:ReviewerStageContractRegistry =
    [System.Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
}

function Get-ReviewerStagePathSegment {
    param([Parameter(Mandatory)][string]$FieldPath)

    $segments = [System.Collections.Generic.List[object]]::new()
    foreach ($part in ($FieldPath -split '\.')) {
        if ([string]::IsNullOrWhiteSpace($part)) {
            throw "Collection field path '$FieldPath' has an empty segment."
        }
        $name = $part
        $each = $false
        if ($part.EndsWith('[*]')) {
            $each = $true
            $name = $part.Substring(0, $part.Length - 3)
        }
        if ($name -notmatch '^[A-Za-z_][A-Za-z0-9_-]*$') {
            throw "Collection field path '$FieldPath' has an unsupported segment '$part'."
        }
        [void]$segments.Add([pscustomobject]@{ Name = $name; Each = $each })
    }
    Write-Output -NoEnumerate ([object[]]$segments.ToArray())
}

function Test-ReviewerStageHasMember {
    param($Node, [Parameter(Mandatory)][string]$Name)

    if ($null -eq $Node) { return $false }
    if ($Node -is [System.Collections.IDictionary]) { return $Node.Contains($Name) }
    if ($Node -is [psobject]) {
        return @($Node.PSObject.Properties | Where-Object { $_.Name -ceq $Name }).Count -gt 0
    }
    return $false
}

function Get-ReviewerStageMember {
    param($Node, [Parameter(Mandatory)][string]$Name)

    # A bare return would enumerate the value, so a one-element collection would
    # arrive at the caller as its single element and an empty one as $null.
    # Callers assign this result directly and only then wrap it in @().
    # $null is returned bare: Write-Output -NoEnumerate would hand back a
    # PSObject wrapping nothing, which is not $null and not a collection.
    # Direct assignment per branch: assigning from an if expression would route
    # the value through the pipeline and enumerate it, which is the very
    # collapse this accessor exists to prevent.
    if ($Node -is [System.Collections.IDictionary]) {
        $value = $Node[$Name]
    }
    else {
        # An absent property is $null, not an error: the caller distinguishes
        # absent from empty with Test-ReviewerStageHasMember.
        $property = $Node.PSObject.Properties[$Name]
        if ($null -eq $property) { return $null }
        $value = $property.Value
    }
    if ($null -eq $value) { return $null }
    # Write-Output -NoEnumerate binds a scalar to its [PSObject[]] parameter and
    # hands back a one-element list, so every non-array member would arrive at
    # the caller as a wrapper instead of itself: a nested object would stop
    # answering Test-ReviewerStageHasMember, and a bare scalar would look like a
    # container. Only a genuine enumerable needs the no-enumerate guard; a
    # string, a dictionary, and a PSObject already cross the boundary intact.
    if ($value -is [System.Collections.IEnumerable] -and
        $value -isnot [string] -and
        $value -isnot [System.Collections.IDictionary]) {
        Write-Output -NoEnumerate $value
        return
    }
    return $value
}

function ConvertTo-ReviewerStageArray {
    <#
    .SYNOPSIS
        Materializes any value as a real object[] without enumerating strings or
        dictionaries.

    .DESCRIPTION
        Crossing a function boundary wraps a value in a PSObject, and PowerShell
        7.4 fails to bind @() against a PSObject-wrapped generic collection with
        "Argument types do not match". Unwrapping the base object first and
        copying the elements explicitly keeps the boundary deterministic instead
        of depending on which call site the runtime bound first.
    #>
    param($Value)

    if ($null -eq $Value) {
        Write-Output -NoEnumerate ([object[]]@())
        return
    }
    $base = $Value
    while ($base -is [psobject] -and $null -ne $base.PSObject.BaseObject -and -not [object]::ReferenceEquals($base, $base.PSObject.BaseObject)) {
        $base = $base.PSObject.BaseObject
    }
    if ($null -eq $base) {
        Write-Output -NoEnumerate ([object[]]@())
        return
    }
    if ($base -is [string] -or $base -is [System.Collections.IDictionary] -or $base -isnot [System.Collections.IEnumerable]) {
        Write-Output -NoEnumerate ([object[]]@($base))
        return
    }
    $items = [System.Collections.Generic.List[object]]::new()
    foreach ($item in $base) { [void]$items.Add($item) }
    Write-Output -NoEnumerate ([object[]]$items.ToArray())
}

function Set-ReviewerStageMember {
    param($Node, [Parameter(Mandatory)][string]$Name, $Value)

    if ($Node -is [System.Collections.IDictionary]) {
        $Node[$Name] = $Value
        return
    }
    if ($null -eq $Node.PSObject.Properties[$Name]) {
        Add-Member -InputObject $Node -MemberType NoteProperty -Name $Name -Value $Value -Force
        return
    }
    $Node.PSObject.Properties[$Name].Value = $Value
}

function Get-ReviewerStageFieldSite {
    <#
    .SYNOPSIS
        Resolves a declared collection path to the concrete parent/name sites
        that exist in a payload, expanding [*] over real elements.
    #>
    param(
        [Parameter(Mandatory)]$Payload,
        [Parameter(Mandatory)][string]$FieldPath
    )

    # Assign the protected list directly. Wrapping a Write-Output -NoEnumerate
    # return in @() nests the whole list as one element instead of flattening it.
    $segments = Get-ReviewerStagePathSegment -FieldPath $FieldPath
    $sites = [System.Collections.Generic.List[object]]::new()
    [void]$sites.Add([pscustomobject]@{ Node = $Payload; Prefix = '' })

    for ($index = 0; $index -lt $segments.Count; $index++) {
        $segment = $segments[$index]
        $isLast = ($index -eq ($segments.Count - 1))
        $next = [System.Collections.Generic.List[object]]::new()
        foreach ($site in $sites) {
            if ($isLast) {
                # A terminal segment always registers a site, even when the
                # member is absent and even when it is written "name[*]". A
                # declared collection that an element simply omits, or that
                # arrived as null or zero-element, has no children to walk -
                # and those are precisely the shapes the boundary must judge,
                # so pruning them here would make the reader fail open.
                [void]$next.Add([pscustomobject]@{
                        Parent = $site.Node
                        Name = $segment.Name
                        Path = ($site.Prefix + $segment.Name)
                    })
                continue
            }
            if (-not (Test-ReviewerStageHasMember -Node $site.Node -Name $segment.Name)) { continue }
            $value = Get-ReviewerStageMember -Node $site.Node -Name $segment.Name
            if ($null -eq $value) { continue }
            if ($segment.Each) {
                $elements = ConvertTo-ReviewerStageArray -Value $value
                for ($elementIndex = 0; $elementIndex -lt $elements.Count; $elementIndex++) {
                    [void]$next.Add([pscustomobject]@{
                            Node = $elements[$elementIndex]
                            Prefix = ($site.Prefix + $segment.Name + "[$elementIndex].")
                        })
                }
                continue
            }
            [void]$next.Add([pscustomobject]@{
                    Node = $value
                    Prefix = ($site.Prefix + $segment.Name + '.')
                })
        }
        $sites = $next
    }
    Write-Output -NoEnumerate ([object[]]$sites.ToArray())
}

function ConvertTo-ReviewerStageCollection {
    <#
    .SYNOPSIS
        Rewrites every declared collection field in place so it is a real array,
        including the zero- and one-element cases that PowerShell would
        otherwise publish as null or as a bare scalar.
    #>
    param(
        [Parameter(Mandatory)]$Payload,
        [string[]]$CollectionFields = @()
    )

    foreach ($fieldPath in @($CollectionFields)) {
        $sites = Get-ReviewerStageFieldSite -Payload $Payload -FieldPath $fieldPath
        foreach ($site in $sites) {
            # An absent member is left absent: fabricating it here would hide a
            # missing required field from Test-ReviewerStagePayloadField and
            # turn a producer defect into a silently well-formed artifact. The
            # shape check reports it instead.
            if (-not (Test-ReviewerStageHasMember -Node $site.Parent -Name $site.Name)) { continue }
            $value = Get-ReviewerStageMember -Node $site.Parent -Name $site.Name
            if ($null -eq $value) {
                Set-ReviewerStageMember -Node $site.Parent -Name $site.Name -Value ([object[]]@())
                continue
            }
            # The helper keeps a hashtable, a string, and a psobject as one
            # element, expands a real collection, and yields zero elements for an
            # empty one - which is exactly the distinction the boundary must keep.
            Set-ReviewerStageMember -Node $site.Parent -Name $site.Name -Value (ConvertTo-ReviewerStageArray -Value $value)
        }
    }
    return $Payload
}

function Test-ReviewerStageCollectionShape {
    <#
    .SYNOPSIS
        Returns the list of declared collection fields whose on-disk value is
        not an array. An empty result means every declared collection survived.
    #>
    param(
        [Parameter(Mandatory)]$Payload,
        [string[]]$CollectionFields = @()
    )

    $violations = [System.Collections.Generic.List[string]]::new()
    foreach ($fieldPath in @($CollectionFields)) {
        $sites = Get-ReviewerStageFieldSite -Payload $Payload -FieldPath $fieldPath
        foreach ($site in $sites) {
            if (-not (Test-ReviewerStageHasMember -Node $site.Parent -Name $site.Name)) {
                # Absent is not the same as empty. A consumer under
                # Set-StrictMode throws on the missing member, so the boundary
                # has to reject it here rather than read past it.
                [void]$violations.Add("$($site.Path) is missing")
                continue
            }
            $value = Get-ReviewerStageMember -Node $site.Parent -Name $site.Name
            if ($value -is [object[]] -or $value -is [System.Array]) { continue }
            $observed = 'null'
            if ($null -ne $value) { $observed = $value.GetType().Name }
            [void]$violations.Add("$($site.Path) collapsed to $observed")
        }
    }
    Write-Output -NoEnumerate ([string[]]$violations.ToArray())
}

function Test-ReviewerStageMapShape {
    <#
    .SYNOPSIS
        Returns the list of declared map fields whose value is not a keyed
        object. An empty result means every declared map survived.

    .DESCRIPTION
        A map is not a list, and the two collapse in opposite directions. An
        empty map that reaches JSON as [] can never read back as a keyed object,
        and a scalar where a map was declared has no repair at all: a map has
        keys and a scalar has none, so inventing one would fabricate data the
        producer never emitted. Both are reported here rather than normalized.
    #>
    param(
        [Parameter(Mandatory)]$Payload,
        [string[]]$MapFields = @()
    )

    $violations = [System.Collections.Generic.List[string]]::new()
    foreach ($fieldPath in @($MapFields)) {
        $sites = Get-ReviewerStageFieldSite -Payload $Payload -FieldPath $fieldPath
        foreach ($site in $sites) {
            if (-not (Test-ReviewerStageHasMember -Node $site.Parent -Name $site.Name)) {
                [void]$violations.Add("$($site.Path) is missing")
                continue
            }
            $value = Get-ReviewerStageMember -Node $site.Parent -Name $site.Name
            if ($null -eq $value) {
                [void]$violations.Add("$($site.Path) collapsed to null")
                continue
            }
            if ($value -is [System.Array]) {
                [void]$violations.Add("$($site.Path) collapsed to an array")
                continue
            }
            if ($value -is [System.Collections.IDictionary]) { continue }
            # A list is not a map, and it is the collapse the array test above
            # cannot see: List<T>, ArrayList and HashSet are all non-array
            # enumerables that PowerShell hands back inside a PSObject, so the
            # keyed-object test below would otherwise wave them through and a
            # per-path span map would reach JSON as a bare sequence of spans
            # with every path silently dropped.
            $enumerable = $value
            if ($value -is [psobject] -and $null -ne $value.PSObject.BaseObject) { $enumerable = $value.PSObject.BaseObject }
            if ($enumerable -is [System.Collections.IEnumerable] -and $enumerable -isnot [string] -and
                $enumerable -isnot [System.Collections.IDictionary]) {
                [void]$violations.Add("$($site.Path) collapsed to a $($enumerable.GetType().Name) sequence")
                continue
            }
            if ($value -is [psobject] -and $value.PSObject.BaseObject -isnot [System.Array] -and
                $value.PSObject.BaseObject -isnot [string] -and $value.PSObject.BaseObject -isnot [ValueType]) {
                continue
            }
            [void]$violations.Add("$($site.Path) collapsed to $($value.GetType().Name)")
        }
    }
    Write-Output -NoEnumerate ([string[]]$violations.ToArray())
}

function Test-ReviewerStagePayloadField {
    param(
        [Parameter(Mandatory)]$Payload,
        [Parameter(Mandatory)]$Contract
    )

    if ($Payload -is [System.Array] -or ($Payload -is [psobject] -and $Payload.PSObject.BaseObject -is [System.Array])) {
        throw "Stage contract '$($Contract.Kind)' payload must be an object, not an array."
    }
    if ($Payload -isnot [psobject] -and $Payload -isnot [System.Collections.IDictionary]) {
        throw "Stage contract '$($Contract.Kind)' payload collapsed to a bare $(if ($null -eq $Payload) { 'null' } else { $Payload.GetType().Name })."
    }
    $present = [System.Collections.Generic.List[string]]::new()
    if ($Payload -is [System.Collections.IDictionary]) {
        foreach ($key in (ConvertTo-ReviewerStageArray -Value $Payload.Keys)) { [void]$present.Add([string]$key) }
    }
    else {
        foreach ($property in (ConvertTo-ReviewerStageArray -Value $Payload.PSObject.Properties)) { [void]$present.Add([string]$property.Name) }
    }
    $missing = @($Contract.RequiredFields | Where-Object { $present -cnotcontains $_ })
    if ($missing.Count -gt 0) {
        throw "Stage contract '$($Contract.Kind)' payload is missing required field(s): $($missing -join ', ')."
    }
    $known = [string[]]@(@($Contract.RequiredFields) + @($Contract.OptionalFields))
    $unknown = @($present | Where-Object { $known -cnotcontains $_ })
    if ($unknown.Count -gt 0) {
        throw "Stage contract '$($Contract.Kind)' payload has unknown field(s): $($unknown -join ', '). Add them to the contract before writing them."
    }
}

function Test-ReviewerStageProducerCollectionShape {
    <#
    .SYNOPSIS
        Returns the declared collection fields a PRODUCER may not hand over.

    .DESCRIPTION
        The write-side shape check judges what is already an array, which is the
        right question for bytes on their way to disk and the wrong one for a
        producer: a stage legitimately builds its result in a List or a HashSet,
        and demanding it pre-materialize an object[] would only move the
        conversion - and the chance to get it wrong - back into the stage.

        What a producer may never hand over is a value that has already lost its
        cardinality: $null (an empty result that became "no result"), a bare
        string or value type (a one-element result that became its element), or a
        dictionary where a list was declared. Those are refused here, before the
        normalizer would repair them into a plausible-looking array and hide the
        defect that produced them. Everything else is a real collection and is
        materialized by ConvertTo-ReviewerStageCollection.
    #>
    param(
        [Parameter(Mandatory)]$Payload,
        [string[]]$CollectionFields = @()
    )

    $violations = [System.Collections.Generic.List[string]]::new()
    foreach ($fieldPath in @($CollectionFields)) {
        $sites = Get-ReviewerStageFieldSite -Payload $Payload -FieldPath $fieldPath
        foreach ($site in $sites) {
            if (-not (Test-ReviewerStageHasMember -Node $site.Parent -Name $site.Name)) {
                [void]$violations.Add("$($site.Path) is missing")
                continue
            }
            $value = Get-ReviewerStageMember -Node $site.Parent -Name $site.Name
            if ($null -eq $value) {
                [void]$violations.Add("$($site.Path) collapsed to null")
                continue
            }
            if ($value -is [string]) {
                [void]$violations.Add("$($site.Path) collapsed to a bare String")
                continue
            }
            if ($value -is [System.Collections.IDictionary]) {
                [void]$violations.Add("$($site.Path) collapsed to a keyed $($value.GetType().Name)")
                continue
            }
            if ($value -is [System.Collections.IEnumerable]) { continue }
            $base = $value
            if ($base -is [psobject] -and $null -ne $base.PSObject.BaseObject) { $base = $base.PSObject.BaseObject }
            if ($base -is [System.Collections.IEnumerable] -and $base -isnot [string] -and
                $base -isnot [System.Collections.IDictionary]) {
                continue
            }
            [void]$violations.Add("$($site.Path) collapsed to a bare $($value.GetType().Name)")
        }
    }
    Write-Output -NoEnumerate ([string[]]$violations.ToArray())
}

function Add-ReviewerStageContractLedgerEntry {
    param(
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)][string]$Producer,
        [Parameter(Mandatory)][ValidateSet('assert', 'write', 'read')][string]$Operation,
        [AllowNull()]$ObservedCounts = $null
    )

    $counts = [ordered]@{}
    if ($null -ne $ObservedCounts -and $ObservedCounts -is [System.Collections.IDictionary]) {
        foreach ($key in $ObservedCounts.Keys) { $counts[[string]$key] = [int]$ObservedCounts[$key] }
    }
    $script:ReviewerStageContractLedgerSequence++
    [void]$script:ReviewerStageContractLedger.Add([pscustomobject][ordered]@{
            Sequence = $script:ReviewerStageContractLedgerSequence
            Kind = $Kind
            Producer = $Producer
            Operation = $Operation
            # The cardinality the boundary actually judged, per declared collection
            # field. Without this the ledger only proves that a validator returned,
            # which is not evidence that any particular census crossed the boundary.
            ObservedCounts = $counts
        })
    # Evict oldest-first rather than growing without bound. RemoveRange is one
    # shift instead of one per entry, so a long-lived process pays this once per
    # overflow rather than on every crossing.
    $overflow = $script:ReviewerStageContractLedger.Count - $script:ReviewerStageContractLedgerMaxEntries
    if ($overflow -gt 0) { $script:ReviewerStageContractLedger.RemoveRange(0, $overflow) }
}

function ConvertTo-ReviewerStageDeterministicKeyOrder {
    <#
    .SYNOPSIS
        A payload whose object keys have been given a stable, ordinal order.
    .DESCRIPTION
        The published bytes are the hashed artifact, so any part of serialization
        that is not a function of the payload's content becomes a digest that
        differs between two runs that observed exactly the same evidence. A plain
        hashtable enumerates in whatever order its buckets happen to sit in, which
        is not part of what the caller expressed, so two identical payloads can
        serialize to two different byte streams and defeat the differential the
        artifact exists to support.

        EVERY object is ordered, whatever PowerShell type it arrived as. Ordering
        only the unordered types would make wire identity a function of the type
        the producer happened to build with: the same logical object would hash
        one way as a hashtable, another as an ordered dictionary and a third as a
        PSCustomObject. A JSON object has no order to preserve, so there is no
        author intent to lose here - and where order genuinely carries meaning it
        belongs in an array, which is left exactly as given.

        The comparison is ordinal, not cultural. Sort-Object collates under the
        current culture even with -CaseSensitive, so a key set containing paths or
        mixed case can order differently on two hosts, or on one host after an ICU
        update, and the artifact digest would then be a function of the machine's
        locale rather than of the evidence.
    #>
    param([AllowNull()]$Node, [int]$Depth = 0)

    if ($Depth -gt 64) {
        throw 'Stage payload nested deeper than 64 levels while ordering keys.'
    }
    if ($null -eq $Node) { return $null }
    if ($Node -is [string] -or $Node -is [System.ValueType]) { return $Node }

    if ($Node -is [System.Collections.IDictionary]) {
        $ordered = [ordered]@{}
        # The ORIGINAL key object is kept alongside its string projection: a
        # dictionary may be keyed by something that is not a string, and looking
        # the value up by the projection would silently miss it and publish a
        # null where evidence was. Two keys whose projections collide are a
        # refusal, not a last-writer-wins.
        $byName = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
        $names = [System.Collections.Generic.List[string]]::new()
        foreach ($key in $Node.Keys) {
            $name = [string]$key
            if ($byName.ContainsKey($name)) {
                throw "Stage payload holds two keys that render as '$name'; a JSON object cannot carry both."
            }
            $byName[$name] = $Node[$key]
            [void]$names.Add($name)
        }
        $keys = [string[]]$names.ToArray()
        [Array]::Sort($keys, [StringComparer]::Ordinal)
        foreach ($key in $keys) {
            $ordered[$key] = ConvertTo-ReviewerStageDeterministicKeyOrder -Node $byName[$key] -Depth ($Depth + 1)
        }
        return $ordered
    }

    if ($Node -is [System.Management.Automation.PSCustomObject]) {
        $ordered = [ordered]@{}
        $properties = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
        $names = [System.Collections.Generic.List[string]]::new()
        foreach ($property in $Node.PSObject.Properties) {
            $name = [string]$property.Name
            if ($properties.ContainsKey($name)) {
                throw "Stage payload holds two properties named '$name'; a JSON object cannot carry both."
            }
            $properties[$name] = $property.Value
            [void]$names.Add($name)
        }
        $sorted = [string[]]$names.ToArray()
        [Array]::Sort($sorted, [StringComparer]::Ordinal)
        foreach ($name in $sorted) {
            $ordered[$name] = ConvertTo-ReviewerStageDeterministicKeyOrder -Node $properties[$name] -Depth ($Depth + 1)
        }
        return [pscustomobject]$ordered
    }

    if ($Node -is [System.Collections.IEnumerable]) {
        $items = [System.Collections.Generic.List[object]]::new()
        foreach ($item in $Node) {
            [void]$items.Add((ConvertTo-ReviewerStageDeterministicKeyOrder -Node $item -Depth ($Depth + 1)))
        }
        # Rebuilt as object[] and returned through the comma operator rather than
        # bare: a returned array unrolls, so an empty one would come back as null
        # and a single-element one as a scalar, collapsing exactly the cardinality
        # the collection normalizer just finished protecting.
        return ,([object[]]$items.ToArray())
    }

    return $Node
}

function Measure-ReviewerStageFieldCardinality {
    <#
    .SYNOPSIS
        The element count of every declared collection field in a normalized
        payload, without enumerating the payload into the pipeline.
    #>
    param(
        [Parameter(Mandatory)][AllowNull()]$Payload,
        [AllowNull()][string[]]$CollectionFields = @()
    )

    $counts = [ordered]@{}
    if ($null -eq $Payload -or $null -eq $CollectionFields) { return $counts }
    foreach ($field in $CollectionFields) {
        if (-not (Test-ReviewerStageHasMember -Node $Payload -Name $field)) { continue }
        $value = Get-ReviewerStageMember -Node $Payload -Name $field
        if ($null -eq $value) { $counts[[string]$field] = -1; continue }
        $collection = $value -as [System.Collections.ICollection]
        if ($null -ne $collection) {
            $counts[[string]$field] = [int]$collection.Count
            continue
        }
        if ($value -is [System.Collections.IEnumerable] -and $value -isnot [string]) {
            $observed = 0
            $enumerator = $value.GetEnumerator()
            while ($enumerator.MoveNext()) { $observed++ }
            $counts[[string]$field] = $observed
            continue
        }
        # A scalar that reached here is a collapse the caller is about to refuse;
        # -1 keeps it distinguishable from a genuine empty census.
        $counts[[string]$field] = -1
    }
    return $counts
}

function Get-ReviewerStageContractLedger {
    <#
    .SYNOPSIS
        The recorded boundary calls, in call order, as a real collection at zero,
        one, and many entries.
    #>
    Write-Output -NoEnumerate ([object[]]$script:ReviewerStageContractLedger.ToArray())
}

function Clear-ReviewerStageContractLedger {
    $script:ReviewerStageContractLedgerSequence = 0
    $script:ReviewerStageContractLedger = [System.Collections.Generic.List[object]]::new()
}

function Assert-ReviewerStageContract {
    <#
    .SYNOPSIS
        Judges one stage payload at the producer boundary and hands back the
        normalized payload the stage must go on to use.

    .DESCRIPTION
        This is the in-memory half of the file contract: the same registered
        kind, the same required/unknown field policy, and the same collection and
        map shape rules, applied before the value is consumed downstream or
        persisted, rather than after it has already crossed a boundary.

        The verdict is the return value, not a side effect. A stage assigns it
        and reads its own result back out of it, so a removed or neutered call
        does not leave a quietly unvalidated payload behind - it leaves an
        undefined variable, which fails under Set-StrictMode at the first read.
    #>
    param(
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)][AllowNull()]$Payload,
        [Parameter(Mandatory)][string]$Producer,
        [switch]$AllowRepair
    )

    $contract = Get-ReviewerStageContract -Kind $Kind
    if ([string]::IsNullOrWhiteSpace($Producer)) {
        throw "Stage contract '$Kind' was asserted without naming its producer."
    }
    if ($null -eq $Payload) {
        throw "Stage contract '$Kind' producer '$Producer' handed over a null payload."
    }
    if (-not $AllowRepair) {
        # Repairing here would turn the producer's own collapse into a
        # well-formed artifact, which is the failure this boundary exists to
        # make visible. Callers that are deliberately re-shaping an inherited
        # artifact ask for the repair explicitly.
        $producerViolations = Test-ReviewerStageProducerCollectionShape -Payload $Payload `
            -CollectionFields $contract.CollectionFields
        if ($producerViolations.Count -gt 0) {
            throw "Stage contract '$Kind' producer '$Producer' handed over collapsed collection field(s): $($producerViolations -join '; ')."
        }
    }

    $normalized = ConvertTo-ReviewerStageCollection -Payload $Payload -CollectionFields $contract.CollectionFields
    Test-ReviewerStagePayloadField -Payload $normalized -Contract $contract
    $collapsed = Test-ReviewerStageCollectionShape -Payload $normalized -CollectionFields $contract.CollectionFields
    if ($collapsed.Count -gt 0) {
        throw "Stage contract '$Kind' producer '$Producer' could not preserve collection field(s): $($collapsed -join '; ')."
    }
    $mapCollapsed = Test-ReviewerStageMapShape -Payload $normalized -MapFields $contract.MapFields
    if ($mapCollapsed.Count -gt 0) {
        throw "Stage contract '$Kind' producer '$Producer' handed over unusable map field(s): $($mapCollapsed -join '; ')."
    }

    Add-ReviewerStageContractLedgerEntry -Kind $contract.Kind -Producer $Producer -Operation 'assert' `
        -ObservedCounts (Measure-ReviewerStageFieldCardinality -Payload $normalized `
            -CollectionFields $contract.CollectionFields)
    return $normalized
}

function Assert-ReviewerStageArtifactOnDisk {
    <#
    .SYNOPSIS
        Re-reads a just-written artifact and returns its VERIFIED on-disk digest.

    .DESCRIPTION
        Hashes the bytes actually on disk and compares them against the digest of
        the bytes the writer intended to publish. A length-only check would pass
        a same-length substitution made after the move, and hashing the intended
        bytes to report the digest would then publish a digest that does not
        describe the file. Both are refused here; the returned digest is the one
        taken over the bytes that are really on disk.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)][byte[]]$IntendedBytes
    )
    $written = [IO.File]::ReadAllBytes($Path)
    if ($written.Length -ne $IntendedBytes.Length) {
        throw "Stage contract '$Kind' did not land intact at '$Path'."
    }
    $intendedDigest = [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData($IntendedBytes)).ToLowerInvariant()
    $digest = [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData($written)).ToLowerInvariant()
    if ($digest -cne $intendedDigest) {
        throw "Stage contract '$Kind' bytes on disk at '$Path' do not match the intended digest; the artifact was altered between write and verification."
    }
    return $digest
}

function Write-ReviewerStageArtifact {
    <#
    .SYNOPSIS
        Writes one stage contract to a caller-named file, atomically.

    .DESCRIPTION
        -Depth and -Form are mandatory: a stage states the serialized shape of
        its own contract rather than inheriting a host default. The file is
        written to a sibling temporary name and moved into place, so a reader
        never observes a partially written contract, and the bytes are read
        back and compared before the write is reported as successful.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)]$Payload,
        [Parameter(Mandatory)][ValidateRange(2, 64)][int]$Depth,
        [Parameter(Mandatory)][ValidateSet('compact', 'indented')][string]$Form,
        [int]$MaxBytes = $script:ReviewerStageContractMaxBytes,
        [switch]$StrictShape
    )

    $contract = Get-ReviewerStageContract -Kind $Kind
    $directory = Split-Path -Parent $Path
    if ([string]::IsNullOrWhiteSpace($directory)) {
        throw "Stage artifact path '$Path' must name a directory; a stage never writes its contract to the working directory by accident."
    }
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        throw "Stage artifact directory '$directory' does not exist."
    }

    if ($StrictShape) {
        # Normalization repairs a collapsed collection, which is what a caller
        # usually wants but also hides the producer defect that caused it. A
        # stage that wants its own bugs reported rather than repaired asks for
        # the pre-normalization verdict.
        $producerCollapsed = Test-ReviewerStageCollectionShape -Payload $Payload -CollectionFields $contract.CollectionFields
        if ($producerCollapsed.Count -gt 0) {
            throw "Stage contract '$Kind' received collapsed collection field(s) from its producer: $($producerCollapsed -join '; ')."
        }
    }

    $normalized = ConvertTo-ReviewerStageCollection -Payload $Payload -CollectionFields $contract.CollectionFields
    Test-ReviewerStagePayloadField -Payload $normalized -Contract $contract
    $collapsed = Test-ReviewerStageCollectionShape -Payload $normalized -CollectionFields $contract.CollectionFields
    if ($collapsed.Count -gt 0) {
        throw "Stage contract '$Kind' could not preserve collection field(s): $($collapsed -join '; ')."
    }
    # Maps are checked but never repaired: there is no correct rewrite from an
    # array or a scalar to a keyed object.
    $mapCollapsed = Test-ReviewerStageMapShape -Payload $normalized -MapFields $contract.MapFields
    if ($mapCollapsed.Count -gt 0) {
        throw "Stage contract '$Kind' received unusable map field(s): $($mapCollapsed -join '; ')."
    }

    $envelope = [ordered]@{
        envelopeVersion = $script:ReviewerStageContractEnvelopeVersion
        kind = $contract.Kind
        contractVersion = $contract.ContractVersion
        form = $Form
        depth = $Depth
        payload = (ConvertTo-ReviewerStageDeterministicKeyOrder -Node $normalized)
    }
    $compact = ($Form -ceq 'compact')
    $json = ConvertTo-Json -InputObject $envelope -Depth $Depth -Compress:$compact
    $text = $json.Replace("`r`n", "`n")
    if ($Form -ceq 'compact' -and $text.Contains("`n")) {
        throw "Stage contract '$Kind' declared the compact form but serialized with line breaks."
    }
    if (-not $text.EndsWith("`n")) { $text += "`n" }
    $bytes = $script:ReviewerStageContractUtf8.GetBytes($text)
    if ($bytes.Length -gt $MaxBytes) {
        throw "Stage contract '$Kind' serialized to $($bytes.Length) bytes, above the $MaxBytes-byte cap."
    }

    $temporary = "$Path.$([Guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllBytes($temporary, $bytes)
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }

    $written = [IO.File]::ReadAllBytes($Path)
    # Verify the bytes ON DISK against the digest of the bytes we intended to
    # write, and report the verified on-disk digest. Factored out so a test can
    # substitute same-length bytes between the write and this verification and
    # prove the substitution is caught rather than hidden behind a length check.
    $digest = Assert-ReviewerStageArtifactOnDisk -Path $Path -Kind $Kind -IntendedBytes $bytes
    Add-ReviewerStageContractLedgerEntry -Kind $contract.Kind -Producer 'Write-ReviewerStageArtifact' -Operation 'write'
    return [pscustomobject][ordered]@{
        Path = $Path
        Kind = $contract.Kind
        ContractVersion = $contract.ContractVersion
        Form = $Form
        Depth = $Depth
        ByteLength = $bytes.Length
        Sha256 = $digest
    }
}

function ConvertTo-ReviewerStageIntegerField {
    <#
    .SYNOPSIS
        Returns a genuinely integral envelope field as an [int], rejecting the
        shapes a bare [int] cast would silently accept.

    .DESCRIPTION
        [int] coerces a quoted "3" to 3, $true to 1, and a fractional 3.7 to 4,
        so a schema check that casts before it validates lets strings, booleans
        and fractional numbers pass as integers. A JSON number parses to an
        integer CLR type when it is whole and to a double when it carries a
        fraction; this accepts the integer types, accepts a double or decimal
        only when it is exactly integral (a JSON 3.0), and rejects everything
        else - including strings, booleans and fractional numbers.
    #>
    param(
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)][string]$FieldName,
        [AllowNull()]$Value
    )
    if ($null -eq $Value) {
        throw "Stage contract '$Kind' field '$FieldName' is null where a JSON integer is required."
    }
    $base = $Value
    if ($base -is [psobject] -and $null -ne $base.PSObject.BaseObject) {
        $base = $base.PSObject.BaseObject
    }
    if ($base -is [bool]) {
        throw "Stage contract '$Kind' field '$FieldName' is a boolean where a JSON integer is required."
    }
    if ($base -is [string] -or $base -is [char]) {
        throw "Stage contract '$Kind' field '$FieldName' is a string where a JSON integer is required."
    }
    $decimalValue = $null
    if ($base -is [byte] -or $base -is [sbyte] -or $base -is [int16] -or $base -is [uint16] -or
        $base -is [int32] -or $base -is [uint32] -or $base -is [int64] -or $base -is [uint64] -or
        $base -is [System.Numerics.BigInteger]) {
        $decimalValue = [decimal]$base
    }
    elseif ($base -is [double] -or $base -is [single] -or $base -is [decimal]) {
        $decimalValue = [decimal]$base
        if ([decimal][math]::Truncate($decimalValue) -ne $decimalValue) {
            throw "Stage contract '$Kind' field '$FieldName' is a fractional number where a JSON integer is required."
        }
    }
    else {
        throw "Stage contract '$Kind' field '$FieldName' is a $($base.GetType().Name) where a JSON integer is required."
    }
    if ($decimalValue -lt [int]::MinValue -or $decimalValue -gt [int]::MaxValue) {
        throw "Stage contract '$Kind' field '$FieldName' value $decimalValue is outside the supported integer range."
    }
    return [int]$decimalValue
}

function Read-ReviewerStageArtifact {
    <#
    .SYNOPSIS
        Reads one stage contract from a file, failing closed on every shape the
        producer was not supposed to be able to publish.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Kind,
        [int]$MaxBytes = $script:ReviewerStageContractMaxBytes
    )

    $contract = Get-ReviewerStageContract -Kind $Kind
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Stage contract '$Kind' artifact '$Path' does not exist."
    }
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -eq 0) {
        throw "Stage contract '$Kind' artifact '$Path' is empty."
    }
    if ($bytes.Length -gt $MaxBytes) {
        throw "Stage contract '$Kind' artifact '$Path' is $($bytes.Length) bytes, above the $MaxBytes-byte cap."
    }
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        throw "Stage contract '$Kind' artifact '$Path' starts with a UTF-8 BOM; contracts are written without one."
    }
    $text = $script:ReviewerStageContractUtf8.GetString($bytes)
    $trimmed = $text.Trim()
    if ($trimmed.Length -eq 0) {
        throw "Stage contract '$Kind' artifact '$Path' contains only whitespace."
    }
    # A stage that printed to stdout and had its stream redirected into the
    # contract file leaves the JSON with a prologue or an epilogue. Both are
    # contamination, and neither is recoverable by parsing harder.
    if (-not $trimmed.StartsWith('{')) {
        throw "Stage contract '$Kind' artifact '$Path' does not begin with a JSON object; stdout contamination or a scalar payload."
    }
    if (-not $trimmed.EndsWith('}')) {
        throw "Stage contract '$Kind' artifact '$Path' does not end with a JSON object; truncated or trailing stdout content."
    }

    $envelope = $null
    try { $envelope = $trimmed | ConvertFrom-Json -Depth 64 }
    catch { throw "Stage contract '$Kind' artifact '$Path' is not parsable JSON: $($_.Exception.Message)" }
    if ($null -eq $envelope -or $envelope -isnot [psobject] -or $envelope -is [System.Array]) {
        throw "Stage contract '$Kind' artifact '$Path' did not parse to a single envelope object."
    }

    $envelopeNames = [System.Collections.Generic.List[string]]::new()
    foreach ($property in (ConvertTo-ReviewerStageArray -Value $envelope.PSObject.Properties)) { [void]$envelopeNames.Add([string]$property.Name) }
    $missingEnvelope = @($script:ReviewerStageContractEnvelopeFields | Where-Object { $envelopeNames -cnotcontains $_ })
    if ($missingEnvelope.Count -gt 0) {
        throw "Stage contract '$Kind' envelope is missing: $($missingEnvelope -join ', ')."
    }
    $unknownEnvelope = @($envelopeNames | Where-Object { $script:ReviewerStageContractEnvelopeFields -cnotcontains $_ })
    if ($unknownEnvelope.Count -gt 0) {
        throw "Stage contract '$Kind' envelope has unknown field(s): $($unknownEnvelope -join ', ')."
    }
    if ((ConvertTo-ReviewerStageIntegerField -Kind $Kind -FieldName 'envelopeVersion' `
                -Value $envelope.envelopeVersion) -ne $script:ReviewerStageContractEnvelopeVersion) {
        throw "Stage contract '$Kind' envelope version $($envelope.envelopeVersion) is not supported."
    }
    if ([string]$envelope.kind -cne $contract.Kind) {
        throw "Stage contract kind mismatch: '$Path' declares '$($envelope.kind)', the reader asked for '$($contract.Kind)'."
    }
    if ($script:ReviewerStageContractForms -cnotcontains [string]$envelope.form) {
        throw "Stage contract '$Kind' declares an unsupported form '$($envelope.form)'."
    }
    $declaredDepth = ConvertTo-ReviewerStageIntegerField -Kind $Kind -FieldName 'depth' -Value $envelope.depth
    if ($declaredDepth -lt 2 -or $declaredDepth -gt 64) {
        throw "Stage contract '$Kind' declares an out-of-range depth $declaredDepth."
    }
    # The declared form has to match the bytes, or the envelope is describing a
    # file that is not the one on disk.
    $isCompactOnDisk = -not $trimmed.Contains("`n")
    if (([string]$envelope.form -ceq 'compact') -ne $isCompactOnDisk) {
        throw "Stage contract '$Kind' artifact '$Path' declares form '$($envelope.form)' but its bytes are $(if ($isCompactOnDisk) { 'compact' } else { 'indented' })."
    }

    $observedVersion = ConvertTo-ReviewerStageIntegerField -Kind $Kind -FieldName 'contractVersion' `
        -Value $envelope.contractVersion
    if ($contract.SupportedVersions -notcontains $observedVersion) {
        throw "Stage contract '$Kind' artifact '$Path' is version $observedVersion; supported versions are $($contract.SupportedVersions -join ', ')."
    }
    $payload = $envelope.payload
    $adapted = $false
    if ($observedVersion -ne $contract.ContractVersion) {
        if (-not $contract.Adapters.Contains($observedVersion)) {
            throw "Stage contract '$Kind' has no registered adapter from version $observedVersion to $($contract.ContractVersion)."
        }
        $adapter = $contract.Adapters[$observedVersion]
        $payload = & $adapter $payload
        $adapted = $true
        if ($null -eq $payload) {
            throw "Stage contract '$Kind' adapter from version $observedVersion produced nothing."
        }
    }

    Test-ReviewerStagePayloadField -Payload $payload -Contract $contract
    $collapsed = Test-ReviewerStageCollectionShape -Payload $payload -CollectionFields $contract.CollectionFields
    if ($collapsed.Count -gt 0) {
        throw "Stage contract '$Kind' artifact '$Path' lost collection shape: $($collapsed -join '; ')."
    }
    $mapCollapsed = Test-ReviewerStageMapShape -Payload $payload -MapFields $contract.MapFields
    if ($mapCollapsed.Count -gt 0) {
        throw "Stage contract '$Kind' artifact '$Path' lost map shape: $($mapCollapsed -join '; ')."
    }

    Add-ReviewerStageContractLedgerEntry -Kind $contract.Kind -Producer 'Read-ReviewerStageArtifact' -Operation 'read'
    return [pscustomobject][ordered]@{
        Path = $Path
        Kind = $contract.Kind
        # The kind and version the FILE declared, as distinct from the kind and
        # version the registry holds. The registry pair is what the reader was
        # asked for and can never disagree with itself; only these two carry what
        # actually came off disk, so a caller comparing provenance has something
        # to compare.
        SourceKind = [string]$envelope.kind
        ContractVersion = $contract.ContractVersion
        SourceVersion = $observedVersion
        Adapted = $adapted
        Form = [string]$envelope.form
        Depth = $declaredDepth
        ByteLength = $bytes.Length
        Sha256 = [Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
        Payload = $payload
    }
}

function Get-ReviewerStageArtifactInventory {
    <#
    .SYNOPSIS
        Read-only census of the stage artifacts under a directory.

    .DESCRIPTION
        Reads bytes and reports what each file claims to be. It never writes,
        moves, or repairs anything, and an unreadable or non-contract file is
        reported as such rather than skipped silently.
    #>
    param(
        [Parameter(Mandatory)][string]$Directory,
        [string]$Filter = '*.json'
    )

    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
        throw "Stage artifact directory '$Directory' does not exist."
    }
    $records = [System.Collections.Generic.List[object]]::new()
    $files = @(Get-ChildItem -LiteralPath $Directory -File -Filter $Filter | Sort-Object Name)
    foreach ($file in $files) {
        $record = [ordered]@{
            Name = $file.Name
            ByteLength = $file.Length
            Kind = ''
            ContractVersion = 0
            Form = ''
            Status = 'unreadable'
            Detail = ''
        }
        try {
            $bytes = [IO.File]::ReadAllBytes($file.FullName)
            $record.ByteLength = $bytes.Length
            $envelope = $script:ReviewerStageContractUtf8.GetString($bytes) | ConvertFrom-Json -Depth 64
            $record.Kind = [string]$envelope.kind
            $record.ContractVersion = [int]$envelope.contractVersion
            $record.Form = [string]$envelope.form
            $record.Status = 'envelope'
        }
        catch {
            $record.Detail = [string]$_.Exception.Message
        }
        [void]$records.Add([pscustomobject]$record)
    }
    Write-Output -NoEnumerate ([object[]]$records.ToArray())
}
