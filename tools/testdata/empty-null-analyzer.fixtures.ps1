# Each function is one independently scored, labeled fixture.

function Receive-FixtureItems {
    param([Parameter(Mandatory)][object[]]$Items)
}

function Get-FixtureItems {
    @()
}

function Positive-TypedArrayAssignment {
    [object[]]$items = Get-FixtureItems
    $items
}

function Negative-PreservedTypedArrayAssignment {
    [object[]]$items = @(Get-FixtureItems)
    $items
}

function Positive-MandatoryArrayArgument {
    Receive-FixtureItems -Items (Get-FixtureItems)
}

function Negative-PreservedMandatoryArrayArgument {
    Receive-FixtureItems -Items @(Get-FixtureItems)
}

function Positive-PhantomNullArray {
    @($null)
}

function Positive-PhantomNullAmongValues {
    @('value', $null)
}

function Negative-FilteredNullArray {
    @($null | Where-Object { $null -ne $_ })
}

function Negative-EmptyArray {
    @()
}

function Positive-UnguardedEmptySum {
    param([object[]]$Items)
    ($Items | Measure-Object -Sum).Sum
}

function Positive-WeakEmptySumGuard {
    param([object[]]$Items)
    if ($Items.Count -ge 0) {
        ($Items | Measure-Object -Sum).Sum
    }
}

function Positive-DisjunctiveEmptySumGuard {
    param([object[]]$Items)
    if ($Items.Count -gt 0 -or $true) {
        ($Items | Measure-Object -Sum).Sum
    }
}

function Negative-DefaultedEmptySum {
    param([object[]]$Items)
    (($Items | Measure-Object -Sum).Sum ?? 0)
}

function Negative-NonEmptyGuardedSum {
    param([object[]]$Items)
    if ($Items.Count -gt 0) {
        ($Items | Measure-Object -Sum).Sum
    }
}

function Negative-ConjunctiveNonEmptyGuardedSum {
    param([object[]]$Items)
    if ($Items.Count -gt 0 -and $true) {
        ($Items | Measure-Object -Sum).Sum
    }
}

function Negative-EarlyReturnGuardedSum {
    param([object[]]$Items)
    if ($Items.Count -eq 0) {
        return 0
    }
    ($Items | Measure-Object -Sum).Sum
}
