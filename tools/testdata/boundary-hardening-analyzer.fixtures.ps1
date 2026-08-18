#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Labeled fixtures for the boundary-hardening analyzer rules PSEN004-PSEN010.

.DESCRIPTION
    Every function here is a labeled measurement case for
    tools/Test-PowerShellBoundaryHardening.ps1. Functions named Positive-* must
    produce at least one finding of their rule inside their own extent, and
    functions named Negative-* must produce none.

    Nothing in this file is executed. The bodies are deliberately hazardous, so
    the file is excluded from the repository boundary gate by name.
#>

# PSEN006 needs a script-scoped name that a script block can read unqualified.
$script:FixtureAmbientState = 'ambient'

function Get-FixtureHelper {
    param([string]$Value = '')
    return $Value
}

# --- PSEN004: bare collection return -----------------------------------------

function Positive-BareCollectionReturn {
    $set = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    return $set
}

function Positive-BareCollectionTrailingExpression {
    $items = New-Object System.Collections.Generic.List[object]
    [void]$items.Add('one')
    $items
}

function Negative-NoEnumerateCollectionReturn {
    $set = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    Write-Output -NoEnumerate $set
}

function Negative-CommaProtectedCollectionReturn {
    $items = New-Object System.Collections.Generic.List[object]
    return , $items
}

function Negative-MaterializedCollectionReturn {
    $items = New-Object System.Collections.Generic.List[object]
    return , $items.ToArray()
}

# --- PSEN005: cardinality read on an unconstrained pipeline -------------------

function Positive-CountOnUnconstrainedPipeline {
    param([string]$Root = '.')
    return (Get-ChildItem -LiteralPath $Root -File).Count
}

function Positive-IndexOnUnconstrainedPipeline {
    param([string]$Root = '.')
    return (Get-ChildItem -LiteralPath $Root -File)[0]
}

function Negative-CountOnPreservedArray {
    param([string]$Root = '.')
    return @(Get-ChildItem -LiteralPath $Root -File).Count
}

function Negative-CountOnLocalArray {
    $values = @('a', 'b')
    return $values.Count
}

# --- PSEN006: unqualified script-scope read inside a script block -------------

function Positive-UnqualifiedScriptScopeInScriptBlock {
    $block = { return $FixtureAmbientState }
    return & $block
}

function Negative-QualifiedScriptScopeInScriptBlock {
    $block = { return $script:FixtureAmbientState }
    return & $block
}

function Negative-ParameterBoundScriptBlock {
    $block = {
        param([string]$FixtureAmbientState)
        return $FixtureAmbientState
    }
    return & $block $script:FixtureAmbientState
}

# --- PSEN007 / PSEN008: serialized contract form ------------------------------

function Positive-ConvertToJsonWithoutDepth {
    param($Value)
    return ($Value | ConvertTo-Json -Compress)
}

function Negative-ConvertToJsonWithDepth {
    param($Value)
    return ($Value | ConvertTo-Json -Depth 8 -Compress)
}

function Positive-ContractWriteWithoutCompress {
    param($Value, [string]$Destination)
    Set-Content -LiteralPath $Destination -Value ($Value | ConvertTo-Json -Depth 8) -Encoding utf8
}

function Negative-ContractWriteWithCompress {
    param($Value, [string]$Destination)
    Set-Content -LiteralPath $Destination -Value ($Value | ConvertTo-Json -Depth 8 -Compress) -Encoding utf8
}

# --- PSEN009: implicit singleton flattening -----------------------------------

function Positive-FlattenedCommandResultCounted {
    param([object[]]$Rows = @())
    $selected = $Rows | Where-Object { $_ }
    return $selected.Count
}

function Negative-PreservedCommandResultCounted {
    param([object[]]$Rows = @())
    $selected = @($Rows | Where-Object { $_ })
    return $selected.Count
}

# --- PSEN010: closure that resolves a repository function by name -------------

function Positive-ClosureCallsRepositoryFunction {
    $prefix = 'value'
    return {
        return Get-FixtureHelper -Value $prefix
    }.GetNewClosure()
}

function Negative-ClosureCapturesFunctionReference {
    $prefix = 'value'
    $helper = ${function:Get-FixtureHelper}
    return {
        return & $helper -Value $prefix
    }.GetNewClosure()
}

# PSEN011: @() around a protected collection return nests it instead of
# flattening it, so an index built from it collapses to one bogus element.
function Negative-ProtectedCollectionSource {
    $items = [System.Collections.Generic.List[object]]::new()
    Write-Output -NoEnumerate ([object[]]$items.ToArray())
}

function Positive-WrapsProtectedCollectionReturn {
    $wrapped = @(Negative-ProtectedCollectionSource)
    return $wrapped.Count
}

function Negative-AssignsProtectedCollectionBeforeWrapping {
    $value = Negative-ProtectedCollectionSource
    $wrapped = @($value)
    return $wrapped.Count
}

# --- exemption soundness: a helper must earn the protected-return exemption ---

# Write-Output with some other named parameter still enumerates, so counting
# this helper's result is a real flattening hazard the exemption must not hide.
function Helper-InputObjectCollectionSource {
    param([object[]]$Rows = @())
    $selected = $Rows | Where-Object { $_ }
    Write-Output -InputObject $selected
}

function Positive-CountsInputObjectHelperResult {
    param([object[]]$Rows = @())
    $found = Helper-InputObjectCollectionSource -Rows $Rows
    return $found.Count
}

# One protected exit does not make the function protected: the bare return
# still enumerates, so the exemption must be withdrawn for the whole helper.
function Helper-MixedProtectionCollectionSource {
    param([object[]]$Rows = @())
    $selected = $Rows | Where-Object { $_ }
    if (@($Rows).Count -eq 0) { return $selected }
    Write-Output -NoEnumerate ([object[]]$selected)
}

function Positive-CountsMixedProtectionHelperResult {
    param([object[]]$Rows = @())
    $found = Helper-MixedProtectionCollectionSource -Rows $Rows
    return $found.Count
}

# The wrapping rule must still fire for a mixed helper: the protected exit
# nests, so @() yields one element holding the whole collection.
function Positive-WrapsMixedProtectionHelperResult {
    param([object[]]$Rows = @())
    $wrapped = @(Helper-MixedProtectionCollectionSource -Rows $Rows)
    return $wrapped.Count
}
