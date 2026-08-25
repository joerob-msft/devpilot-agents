<#
.SYNOPSIS
    Deliberate collection-collapse shapes used by tools/Test-ReviewerCollectionCardinality.ps1.

.DESCRIPTION
    A property test that proves "the unguarded form collapses" needs the unguarded form to
    exist somewhere. Keeping those forms here, rather than in the test body, means the
    boundary hardening analyzer can stay strict about the test itself: this file is on the
    analyzer's exclusion list for the same reason the analyzer's own fixture file is, and
    every hazard in it is intentional and paired with its guarded counterpart.

    Nothing here is executed at load time; the test dot-sources this file and calls the
    functions explicitly.

.NOTES
    Not a test. Contains deliberately hazardous PowerShell.
#>

# Hazard: a locally built set returned bare. The return enumerates it, so an empty set
# arrives as $null and a one-element set arrives as its single member.
function Get-SetBare {
    param([string[]]$Values)
    $set = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($value in $Values) { [void]$set.Add($value) }
    return $set
}

# Guarded counterpart: the same set emitted without enumeration.
function Get-SetProtected {
    param([string[]]$Values)
    $set = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($value in $Values) { [void]$set.Add($value) }
    Write-Output -NoEnumerate $set
}

# Guarded producer: emits its array as a single object so the caller can assign it intact.
function Get-ProtectedSpans {
    param([int]$Count)
    $spans = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $Count; $i++) { [void]$spans.Add("span-$i") }
    return , ([object[]]$spans.ToArray())
}

# Hazard: wrapping a protected return in an array subexpression. Because the value crosses
# the pipeline as one object, the wrap nests it instead of flattening it, so a three-element
# result becomes one element and an empty result becomes one element as well.
function Get-UnguardedSpanWrap {
    param([int]$Count)
    $wrapped = @(Get-ProtectedSpans -Count $Count)
    Write-Output -NoEnumerate $wrapped
}

# Hazard: a filtered pipeline returned bare. No survivors yields $null; one survivor yields
# a bare scalar.
function Get-DifferenceSet {
    param([string[]]$Left, [string[]]$Right)
    return $Left | Where-Object { $Right -notcontains $_ }
}
