#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Proves the twelve stage producer/consumer boundaries are ADOPTED, not merely
    available.

.DESCRIPTION
    tools/Test-ReviewerStageContract.ps1 proves the file contract behaves. This
    suite proves it is in force: that every one of the twelve boundaries is
    registered, that the real producer on each live path calls its builder AND
    reads the verdict back, that a removed or discarded call is caught here
    rather than downstream, and that every stage kind survives a full
    write/read/fault cycle through the versioned file contract.

    The sabotage checks are the point of the static half. A validator whose
    result is thrown away is indistinguishable from no validator at all in every
    test that only exercises well-formed input, so this suite mutates the real
    producer text three ways - call removed, verdict assigned to $null, verdict
    never read - and fails if the checker still calls the boundary adopted.

    No model, no network, no repository write. Files are created only under a
    per-run temporary directory and removed at the end.

.EXAMPLE
    ./tools/Test-ReviewerStageProducerContract.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $repoRoot 'src\Agents\reviewer\StageProducers.ps1')
. (Join-Path $repoRoot 'src\Agents\reviewer\SourceTransport.ps1')
. (Join-Path $repoRoot 'src\Agents\reviewer\CorpusSeal.ps1')
. (Join-Path $repoRoot 'src\Agents\reviewer\ConventionSpecialist.ps1')
. (Join-Path $repoRoot 'src\Agents\reviewer\CrossVerification.ps1')
. (Join-Path $repoRoot 'src\Agents\reviewer\DeliveryGates.ps1')
. (Join-Path $repoRoot 'src\Agents\reviewer\ChangedConstructs.ps1')
. (Join-Path $repoRoot 'src\Agents\reviewer\RunReconciliation.ps1')
. (Join-Path $repoRoot 'src\Agents\reviewer\evaluation\Evaluation.ps1')

$failures = [System.Collections.Generic.List[string]]::new()
$checks = 0

function Assert-Adoption {
    param([bool]$Condition, [Parameter(Mandatory)][string]$Message)
    $script:checks++
    if (-not $Condition) { [void]$script:failures.Add($Message) }
}

function Assert-AdoptionThrows {
    param(
        [Parameter(Mandatory)][scriptblock]$Action,
        [Parameter(Mandatory)][string]$Message,
        [string]$ExpectedMessageLike
    )
    $script:checks++
    $thrown = $null
    try { & $Action | Out-Null } catch { $thrown = $_ }
    if ($null -eq $thrown) { [void]$script:failures.Add($Message); return }
    # A bare "it threw" assertion passes when a typo throws, which would retire
    # the guarantee it claims to hold while still reporting green.
    if ($ExpectedMessageLike -and [string]$thrown.Exception.Message -notlike $ExpectedMessageLike) {
        [void]$script:failures.Add("$Message (threw '$($thrown.Exception.Message)', expected like '$ExpectedMessageLike')")
    }
}

# ---------------------------------------------------------------------------
# Static adoption: does the real producer call its builder and read the verdict?
# ---------------------------------------------------------------------------

function Test-ReviewerStageUnreachableCondition {
    <#
        True when a condition is a literal that can never hold. A boundary call
        parked under `if ($false)` is present in the syntax tree and absent from
        every run, which is un-adoption that a call-site search reports as green.
    #>
    param([Parameter(Mandatory)][AllowNull()]$Condition)

    $expression = $Condition
    while ($true) {
        if ($expression -is [System.Management.Automation.Language.PipelineAst]) {
            $elements = @($expression.PipelineElements)
            if ($elements.Count -ne 1) { return $false }
            $expression = $elements[0]
            continue
        }
        if ($expression -is [System.Management.Automation.Language.CommandExpressionAst]) {
            $expression = $expression.Expression
            continue
        }
        if ($expression -is [System.Management.Automation.Language.ParenExpressionAst]) {
            $expression = $expression.Pipeline
            continue
        }
        break
    }
    if ($expression -is [System.Management.Automation.Language.VariableExpressionAst]) {
        return ([string]$expression.VariablePath.UserPath -iin @('false', 'null'))
    }
    if ($expression -is [System.Management.Automation.Language.ConstantExpressionAst]) {
        return (-not [bool]$expression.Value)
    }
    return $false
}

function Test-ReviewerStageDiscardedVerdictRead {
    <#
        True when a mention of the verdict variable throws the verdict away
        rather than consuming it. `$verdict | Out-Null`, `[void]$verdict` and
        `$null = $verdict` all read the variable, so counting mentions alone
        lets a producer satisfy the adoption check while publishing the
        unvalidated value it had before the boundary.
    #>
    param([Parameter(Mandatory)][System.Management.Automation.Language.Ast]$Read)

    $parent = $Read.Parent
    while ($null -ne $parent -and (
            $parent -is [System.Management.Automation.Language.ParenExpressionAst] -or
            $parent -is [System.Management.Automation.Language.CommandExpressionAst] -or
            $parent -is [System.Management.Automation.Language.ConvertExpressionAst])) {
        if ($parent -is [System.Management.Automation.Language.ConvertExpressionAst] -and
            [string]$parent.Type.TypeName.FullName -imatch '^(void|System\.Void)$') {
            return $true
        }
        $parent = $parent.Parent
    }
    if ($parent -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $parent.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
        [string]$parent.Left.VariablePath.UserPath -ceq 'null') {
        return $true
    }
    if ($parent -is [System.Management.Automation.Language.PipelineAst]) {
        $elements = @($parent.PipelineElements)
        if ($elements.Count -gt 1) {
            $last = $elements[$elements.Count - 1]
            if ($last -is [System.Management.Automation.Language.CommandAst] -and
                [string]$last.GetCommandName() -iin @('Out-Null', 'Out-String', 'Write-Debug', 'Write-Verbose')) {
                return $true
            }
        }
    }
    return $false
}

function Get-ReviewerStageAdoptionViolation {
    <#
        Returns the reasons one producer file does NOT adopt one boundary. An
        empty result means it does.

        This reads the syntax tree rather than the text. A substring search would
        be satisfied by the builder's name in a comment, and would keep passing
        after the call itself was replaced by a constant - which is precisely the
        regression this check exists to catch.

        Failures are reported separately, because they are distinct ways to
        un-adopt a boundary while leaving the file looking right: never calling
        the builder, parking the call under a literal-false clause, assigning
        its verdict to $null, assigning the verdict to a variable that nothing
        reads, reading it only to throw it away, and overwriting the verdict
        before the value that is finally published is read back out.
    #>
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Builder,
        [Parameter(Mandatory)][string]$Producer
    )

    $violations = [System.Collections.Generic.List[string]]::new()
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$null, [ref]$parseErrors)
    if ($null -ne $parseErrors -and @($parseErrors).Count -gt 0) {
        [void]$violations.Add("the producer file does not parse")
        Write-Output -NoEnumerate ([string[]]$violations.ToArray())
        return
    }

    $functions = @($ast.FindAll(
            { param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))
    $assignments = @($ast.FindAll(
            { param($node) $node -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true))

    $callingFunctions = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $sawCall = $false
    $sawConsumedCall = $false
    foreach ($assignment in $assignments) {
        $commands = @($assignment.Right.FindAll(
                { param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true))
        $matched = $false
        foreach ($command in $commands) {
            if ([string]$command.GetCommandName() -ceq $Builder) { $matched = $true }
        }
        if (-not $matched) { continue }
        # A call that can never execute is not adoption. Keeping the assignment
        # under a literal-false clause leaves the builder name in the tree while
        # the boundary is never crossed at run time.
        $unreachable = $false
        $enclosing = $assignment.Parent
        while ($null -ne $enclosing -and $enclosing -isnot [System.Management.Automation.Language.FunctionDefinitionAst]) {
            if ($enclosing -is [System.Management.Automation.Language.IfStatementAst]) {
                foreach ($clause in $enclosing.Clauses) {
                    if ($null -eq $clause.Item2) { continue }
                    if ($clause.Item2.Extent.StartOffset -gt $assignment.Extent.StartOffset) { continue }
                    if ($clause.Item2.Extent.EndOffset -lt $assignment.Extent.EndOffset) { continue }
                    if (Test-ReviewerStageUnreachableCondition -Condition $clause.Item1) { $unreachable = $true }
                }
            }
            $enclosing = $enclosing.Parent
        }
        if ($unreachable) { continue }
        $sawCall = $true
        if ($assignment.Left -isnot [System.Management.Automation.Language.VariableExpressionAst]) { continue }
        $variableName = [string]$assignment.Left.VariablePath.UserPath
        # `$null = builder ...` is the canonical way to keep the call and discard
        # the answer. It is a violation, not an abbreviation.
        if ($variableName -ceq 'null') { continue }

        $container = $assignment.Parent
        while ($null -ne $container -and $container -isnot [System.Management.Automation.Language.FunctionDefinitionAst]) {
            $container = $container.Parent
        }
        if ($null -eq $container) { continue }

        $reads = @($container.Body.FindAll(
                { param($node) $node -is [System.Management.Automation.Language.VariableExpressionAst] }, $true))
        # A later assignment to the same variable replaces the verdict, so every
        # mention past that point reads the replacement. Without this window a
        # producer can call the boundary, overwrite the answer with the value it
        # had before, read *that* back and still be reported as adopted.
        $replacementOffset = [int]::MaxValue
        foreach ($later in $assignments) {
            if ($later.Left -isnot [System.Management.Automation.Language.VariableExpressionAst]) { continue }
            if ([string]$later.Left.VariablePath.UserPath -cne $variableName) { continue }
            if ($later.Extent.StartOffset -le $assignment.Extent.StartOffset) { continue }
            if ($later.Extent.StartOffset -lt $container.Extent.StartOffset) { continue }
            if ($later.Extent.EndOffset -gt $container.Extent.EndOffset) { continue }
            if ($later.Extent.StartOffset -lt $replacementOffset) { $replacementOffset = [int]$later.Extent.StartOffset }
        }
        $readCount = 0
        foreach ($read in $reads) {
            if ([string]$read.VariablePath.UserPath -cne $variableName) { continue }
            # Any assignment target is a write, not a read. Counting the second
            # `$asserted = $null` as a read would let a producer call the builder,
            # overwrite the verdict and still look adopted.
            $parent = $read.Parent
            if ($parent -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                $parent.Left.Extent.StartOffset -eq $read.Extent.StartOffset) {
                continue
            }
            if ($read.Extent.StartOffset -lt $assignment.Extent.EndOffset) { continue }
            if ($read.Extent.StartOffset -ge $replacementOffset) { continue }
            if (Test-ReviewerStageDiscardedVerdictRead -Read $read) { continue }
            $readCount++
        }
        if ($readCount -eq 0) { continue }
        $sawConsumedCall = $true
        [void]$callingFunctions.Add([string]$container.Name)
    }

    if (-not $sawCall) {
        [void]$violations.Add("'$Builder' is never called from an assignment")
    }
    elseif (-not $sawConsumedCall) {
        [void]$violations.Add("'$Builder' is called but its verdict is discarded")
    }
    else {
        # The call has to be reachable from the declared producer, or the
        # boundary is in force somewhere the live path never goes.
        $callGraph = @{}
        foreach ($function in $functions) {
            $invoked = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            foreach ($command in @($function.Body.FindAll(
                        { param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true))) {
                $name = [string]$command.GetCommandName()
                if ($name) { [void]$invoked.Add($name) }
            }
            $callGraph[[string]$function.Name] = $invoked
        }
        if (-not $callGraph.ContainsKey($Producer)) {
            [void]$violations.Add("producer function '$Producer' is not defined in this file")
        }
        else {
            $reached = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            $queue = [System.Collections.Generic.Queue[string]]::new()
            $queue.Enqueue($Producer)
            [void]$reached.Add($Producer)
            $found = $false
            while ($queue.Count -gt 0) {
                $current = $queue.Dequeue()
                if ($callingFunctions.Contains($current)) { $found = $true; break }
                if (-not $callGraph.ContainsKey($current)) { continue }
                foreach ($callee in $callGraph[$current]) {
                    if (-not $callGraph.ContainsKey($callee)) { continue }
                    if ($reached.Add($callee)) { $queue.Enqueue($callee) }
                }
            }
            if (-not $found) {
                [void]$violations.Add("'$Producer' does not reach the consumed '$Builder' call")
            }
        }
    }

    Write-Output -NoEnumerate ([string[]]$violations.ToArray())
}

function New-ReviewerStageAdoptionPayload {
    <#
        A well-formed payload for one boundary, built by the boundary's own
        builder with a representative census in its declared collection slot.
    #>
    param([Parameter(Mandatory)]$Row)

    return Invoke-ReviewerStageProducerBuilder -Stage ([string]$Row.Stage) `
        -Value ([object[]]@('alpha', 'beta')) -Slot 'collection'
}

$sandbox = Join-Path ([IO.Path]::GetTempPath()) ("reviewer-stage-producer-" + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $sandbox -Force

try {
    # Assigned, never @()-wrapped: these helpers deliberately protect their
    # collection return, and @(f x) would wrap the protected array in a
    # one-element array rather than unrolling it.
    $rows = Get-ReviewerStageProducerContract
    # Counted through a local, not through the protected return itself: $rows carries the
    # boundary's own collection and must not be re-wrapped at its use sites.
    $rowCount = 0
    foreach ($countedRow in $rows) { if ($null -ne $countedRow) { $rowCount++ } }
    $expectedStages = [string[]]@(
        'capture', 'source', 'snapshot', 'corpus', 'blindResults', 'candidateUnion',
        'fingerprints', 'specialistPlan', 'verifierAssignment', 'verdict',
        'reconciliation', 'deliveryDecision')

    # -----------------------------------------------------------------------
    # 1. The inventory of boundaries, and the checked-in pin of it.
    # -----------------------------------------------------------------------
    Assert-Adoption ($rowCount -eq 12) `
        "The reviewer declares $($rowCount) stage producer boundaries; twelve are required."
    Assert-Adoption ((@($rows | ForEach-Object { [string]$_.Stage }) -join ',') -ceq ($expectedStages -join ',')) `
        "The stage producer boundaries are not the twelve inventoried stages in run order."

    foreach ($row in $rows) {
        $registered = Get-ReviewerStageContract -Kind ([string]$row.Kind)
        Assert-Adoption ([int]$registered.ContractVersion -eq 1) `
            "Stage '$($row.Stage)' is registered at version $($registered.ContractVersion); the adopted contract is version 1."
        Assert-Adoption (([string[]]$registered.CollectionFields) -ccontains [string]$row.CollectionSlot) `
            "Stage '$($row.Stage)' names a collection slot that is not one of its declared collection fields."
        Assert-Adoption (([string[]]$registered.RequiredFields).Count -gt 0) `
            "Stage '$($row.Stage)' declares no required fields, so its contract asserts nothing."
        foreach ($collectionField in [string[]]$registered.CollectionFields) {
            Assert-Adoption (([string[]]$registered.RequiredFields) -ccontains $collectionField) `
                "Stage '$($row.Stage)' declares optional collection field '$collectionField'; an absent census is not an empty one."
        }
    }

    $schemaPath = Join-Path $repoRoot 'src\Agents\reviewer\schemas\reviewer.stage-producer-contracts.v1.json'
    Assert-Adoption (Test-Path -LiteralPath $schemaPath -PathType Leaf) `
        "The checked-in stage producer contract schema is missing."
    if (Test-Path -LiteralPath $schemaPath -PathType Leaf) {
        $schemaBytes = [IO.File]::ReadAllBytes($schemaPath)
        Assert-Adoption (-not ($schemaBytes.Length -ge 3 -and $schemaBytes[0] -eq 0xEF -and
                $schemaBytes[1] -eq 0xBB -and $schemaBytes[2] -eq 0xBF)) `
            "The stage producer contract schema starts with a UTF-8 BOM."
        $schemaRows = [System.Collections.Generic.List[object]]::new()
        foreach ($row in $rows) {
            $registered = Get-ReviewerStageContract -Kind ([string]$row.Kind)
            [void]$schemaRows.Add([ordered]@{
                    stage = [string]$row.Stage
                    kind = [string]$row.Kind
                    contractVersion = [int]$registered.ContractVersion
                    builder = [string]$row.Builder
                    producer = [string]$row.Producer
                    producerFile = [string]$row.ProducerFile
                    summary = [string]$row.Summary
                    requiredFields = [string[]]$registered.RequiredFields
                    collectionFields = [string[]]$registered.CollectionFields
                    mapFields = [string[]]$registered.MapFields
                    collectionSlot = [string]$row.CollectionSlot
                    mapSlot = [string]$row.MapSlot
                })
        }
        $expectedDocument = [ordered]@{
            schemaVersion = 1
            kind = 'reviewer-stage-producer-contracts'
            description = 'The stage producer/consumer boundaries in force. Generated from src/Agents/reviewer/StageProducers.ps1 and compared against it by tools/Test-ReviewerStageProducerContract.ps1; the runtime table is the source of truth, this file is the pin.'
            boundaries = [object[]]$schemaRows.ToArray()
        }
        $expectedText = (ConvertTo-Json -InputObject $expectedDocument -Depth 12 -Compress:$false).Replace("`r`n", "`n")
        if (-not $expectedText.EndsWith("`n")) { $expectedText += "`n" }
        $actualText = [System.Text.UTF8Encoding]::new($false, $true).GetString($schemaBytes).Replace("`r`n", "`n")
        Assert-Adoption ($actualText -ceq $expectedText) `
            "The checked-in stage producer contract schema has drifted from the runtime boundary table."
    }

    # -----------------------------------------------------------------------
    # 2. Static adoption of every boundary, plus the three sabotages.
    # -----------------------------------------------------------------------
    foreach ($row in $rows) {
        $producerPath = Join-Path $repoRoot ([string]$row.ProducerFile).Replace('/', [IO.Path]::DirectorySeparatorChar)
        Assert-Adoption (Test-Path -LiteralPath $producerPath -PathType Leaf) `
            "Stage '$($row.Stage)' names producer file '$($row.ProducerFile)', which does not exist."
        if (-not (Test-Path -LiteralPath $producerPath -PathType Leaf)) { continue }
        $producerText = [IO.File]::ReadAllText($producerPath)
        $violations = Get-ReviewerStageAdoptionViolation -Text $producerText `
            -Builder ([string]$row.Builder) -Producer ([string]$row.Producer)
        Assert-Adoption ($violations.Count -eq 0) `
            "Stage '$($row.Stage)' is not adopted by '$($row.Producer)': $($violations -join '; ')."
    }

    # The sabotage is run against the source boundary because it is the smallest
    # producer with a single collection field, so a mutation cannot succeed for
    # an unrelated reason. All three mutations must be reported.
    $sourceRow = Get-ReviewerStageProducerContract -Stage 'source'
    $sourcePath = Join-Path $repoRoot ([string]$sourceRow.ProducerFile).Replace('/', [IO.Path]::DirectorySeparatorChar)
    $sourceText = [IO.File]::ReadAllText($sourcePath)

    $removedCall = $sourceText.Replace(
        '$asserted = New-ReviewerSourceStageContract -ChangedPaths $paths',
        '$asserted = [ordered]@{ changedPaths = $paths }')
    Assert-Adoption ($removedCall -cne $sourceText) `
        "The removed-call sabotage did not change the source producer text; the check is not exercising the real call site."
    $removedViolations = Get-ReviewerStageAdoptionViolation -Text $removedCall `
        -Builder ([string]$sourceRow.Builder) -Producer ([string]$sourceRow.Producer)
    Assert-Adoption ($removedViolations.Count -gt 0) `
        "Removing the source stage boundary call left the adoption check reporting the boundary as adopted."

    $discardedVerdict = $sourceText.Replace(
        '$asserted = New-ReviewerSourceStageContract -ChangedPaths $paths',
        '$null = New-ReviewerSourceStageContract -ChangedPaths $paths')
    Assert-Adoption ($discardedVerdict -cne $sourceText) `
        "The discarded-verdict sabotage did not change the source producer text."
    $discardedViolations = Get-ReviewerStageAdoptionViolation -Text $discardedVerdict `
        -Builder ([string]$sourceRow.Builder) -Producer ([string]$sourceRow.Producer)
    Assert-Adoption ($discardedViolations.Count -gt 0) `
        "Assigning the source stage verdict to `$null left the adoption check reporting the boundary as adopted."

    $unreadVerdict = $sourceText.Replace(
        'return ([string[]]@($asserted.changedPaths))',
        'return ([string[]]@($paths))')
    Assert-Adoption ($unreadVerdict -cne $sourceText) `
        "The unread-verdict sabotage did not change the source producer text."
    $unreadViolations = Get-ReviewerStageAdoptionViolation -Text $unreadVerdict `
        -Builder ([string]$sourceRow.Builder) -Producer ([string]$sourceRow.Producer)
    Assert-Adoption ($unreadViolations.Count -gt 0) `
        "Never reading the source stage verdict left the adoption check reporting the boundary as adopted."

    # A second assignment to the verdict variable is a write, not a read. Without
    # this the boundary can be called, immediately overwritten, and the original
    # unvalidated value returned, while the adoption check still reports success.
    $overwrittenVerdict = $sourceText.Replace(
        '$asserted = New-ReviewerSourceStageContract -ChangedPaths $paths',
        "`$asserted = New-ReviewerSourceStageContract -ChangedPaths `$paths`r`n    `$asserted = [ordered]@{ changedPaths = `$paths }")
    $overwrittenVerdict = $overwrittenVerdict.Replace(
        'return ([string[]]@($asserted.changedPaths))',
        'return ([string[]]@($paths))')
    Assert-Adoption ($overwrittenVerdict -cne $sourceText) `
        "The overwritten-verdict sabotage did not change the source producer text."
    $overwrittenViolations = Get-ReviewerStageAdoptionViolation -Text $overwrittenVerdict `
        -Builder ([string]$sourceRow.Builder) -Producer ([string]$sourceRow.Producer)
    Assert-Adoption ($overwrittenViolations.Count -gt 0) `
        "Overwriting the source stage verdict left the adoption check reporting the boundary as adopted."

    # The same overwrite, but the replacement IS read back. Counting mentions of
    # the verdict variable would report this as adopted while every published
    # field comes from the unvalidated value the producer had before the call.
    $overwrittenAndReadVerdict = $sourceText.Replace(
        '$asserted = New-ReviewerSourceStageContract -ChangedPaths $paths',
        "`$asserted = New-ReviewerSourceStageContract -ChangedPaths `$paths`r`n    `$asserted = [ordered]@{ changedPaths = `$paths }")
    Assert-Adoption ($overwrittenAndReadVerdict -cne $sourceText) `
        "The overwritten-and-read-verdict sabotage did not change the source producer text."
    $overwrittenAndReadViolations = Get-ReviewerStageAdoptionViolation -Text $overwrittenAndReadVerdict `
        -Builder ([string]$sourceRow.Builder) -Producer ([string]$sourceRow.Producer)
    Assert-Adoption ($overwrittenAndReadViolations.Count -gt 0) `
        "Reading a verdict that had already been overwritten left the adoption check reporting the boundary as adopted."

    # A call that cannot execute is not a boundary. The builder name stays in the
    # tree, so anything short of reachability analysis reports this as adopted.
    $unreachableCall = $sourceText.Replace(
        '$asserted = New-ReviewerSourceStageContract -ChangedPaths $paths',
        "`$asserted = [ordered]@{ changedPaths = `$paths }`r`n    if (`$false) { `$asserted = New-ReviewerSourceStageContract -ChangedPaths `$paths }")
    Assert-Adoption ($unreachableCall -cne $sourceText) `
        "The unreachable-call sabotage did not change the source producer text."
    $unreachableViolations = Get-ReviewerStageAdoptionViolation -Text $unreachableCall `
        -Builder ([string]$sourceRow.Builder) -Producer ([string]$sourceRow.Producer)
    Assert-Adoption ($unreachableViolations.Count -gt 0) `
        "Parking the source stage boundary under a literal-false clause left the adoption check reporting it as adopted."

    # Reading the verdict into a sink is not consuming it.
    $sunkVerdict = $sourceText.Replace(
        'return ([string[]]@($asserted.changedPaths))',
        "`$asserted | Out-Null`r`n    return ([string[]]@(`$paths))")
    Assert-Adoption ($sunkVerdict -cne $sourceText) `
        "The sunk-verdict sabotage did not change the source producer text."
    $sunkViolations = Get-ReviewerStageAdoptionViolation -Text $sunkVerdict `
        -Builder ([string]$sourceRow.Builder) -Producer ([string]$sourceRow.Producer)
    Assert-Adoption ($sunkViolations.Count -gt 0) `
        "Piping the source stage verdict to Out-Null left the adoption check reporting the boundary as adopted."

    # -----------------------------------------------------------------------
    # 3. Runtime refusal at every boundary, in every collapse shape.
    # -----------------------------------------------------------------------
    $collapseCases = [ordered]@{}
    $collapseCases['null'] = $null
    $collapseCases['bareString'] = 'one-element-that-lost-its-list'
    $collapseCases['bareInteger'] = 7
    $collapseCases['keyedMap'] = @{ zero = 'a' }
    foreach ($row in $rows) {
        foreach ($caseName in $collapseCases.Keys) {
            $caseValue = $collapseCases[$caseName]
            Assert-AdoptionThrows -Action {
                Invoke-ReviewerStageProducerBuilder -Stage ([string]$row.Stage) -Value $caseValue -Slot 'collection'
            } -Message "Stage '$($row.Stage)' accepted a '$caseName' collapse in '$($row.CollectionSlot)'." `
                -ExpectedMessageLike "*handed over collapsed collection field(s)*"
        }
    }

    # A map is not a list, and the only boundary that declares one has to refuse
    # both directions of the collapse.
    Assert-AdoptionThrows -Action {
        Invoke-ReviewerStageProducerBuilder -Stage 'snapshot' -Value ([object[]]@('a')) -Slot 'map'
    } -Message "The snapshot boundary accepted an array where its span map was declared." `
        -ExpectedMessageLike "*unusable map field(s)*"
    Assert-AdoptionThrows -Action {
        Invoke-ReviewerStageProducerBuilder -Stage 'snapshot' -Value $null -Slot 'map'
    } -Message "The snapshot boundary accepted a null span map." `
        -ExpectedMessageLike "*unusable map field(s)*"
    # A non-array sequence is the collapse the array test cannot see: PowerShell
    # hands List<T>/HashSet<T> back inside a PSObject whose BaseObject is neither
    # an array nor a scalar, so a keyed-object test alone waves them through and
    # the per-path span map reaches JSON as a bare sequence with every path gone.
    foreach ($sequence in @(
            [System.Collections.Generic.List[object]]::new([object[]]@('a')),
            [System.Collections.Generic.HashSet[string]]::new([string[]]@('a'), [StringComparer]::Ordinal),
            [System.Collections.ArrayList]::new([object[]]@('a')))) {
        Assert-AdoptionThrows -Action {
            Invoke-ReviewerStageProducerBuilder -Stage 'snapshot' -Value $sequence -Slot 'map'
        } -Message "The snapshot boundary accepted a $($sequence.GetType().Name) where its span map was declared." `
            -ExpectedMessageLike "*unusable map field(s)*"
    }

    # -----------------------------------------------------------------------
    # 4. Acceptance at every cardinality the corpus cares about.
    # -----------------------------------------------------------------------
    $cardinalities = [ordered]@{}
    $cardinalities['zero'] = [object[]]@()
    $cardinalities['one'] = [object[]]@('only')
    $cardinalities['many'] = [object[]]@('a', 'b', 'c')
    $cardinalities['duplicate'] = [object[]]@('same', 'same')
    $cardinalities['listOfOne'] = [System.Collections.Generic.List[string]]::new([string[]]@('only'))
    $cardinalities['hashSet'] = [System.Collections.Generic.HashSet[string]]::new(
        [string[]]@('a', 'b'), [StringComparer]::Ordinal)
    foreach ($row in $rows) {
        foreach ($caseName in $cardinalities.Keys) {
            $published = Invoke-ReviewerStageProducerBuilder -Stage ([string]$row.Stage) `
                -Value $cardinalities[$caseName] -Slot 'collection'
            $slotValue = Get-ReviewerStageMember -Node $published -Name ([string]$row.CollectionSlot)
            Assert-Adoption ($slotValue -is [object[]]) `
                "Stage '$($row.Stage)' published '$caseName' as $(if ($null -eq $slotValue) { 'null' } else { $slotValue.GetType().Name }) rather than an array."
            Assert-Adoption ([int]([object[]]$slotValue).Count -eq [int]@($cardinalities[$caseName]).Count) `
                "Stage '$($row.Stage)' changed the element count of '$caseName' at its boundary."
        }
    }

    # -----------------------------------------------------------------------
    # 5. The ledger: adoption is mechanically observable, per boundary.
    # -----------------------------------------------------------------------
    Clear-ReviewerStageContractLedger
    Assert-Adoption ((Get-ReviewerStageContractLedger).Count -eq 0) `
        "The stage contract ledger did not clear."
    foreach ($row in $rows) {
        $null = New-ReviewerStageAdoptionPayload -Row $row
    }
    $ledger = Get-ReviewerStageContractLedger
    Assert-Adoption ($ledger.Count -eq $rowCount) `
        "The ledger recorded $($ledger.Count) boundary calls for $($rowCount) boundaries."
    foreach ($row in $rows) {
        $entries = @($ledger | Where-Object {
                [string]$_.Kind -ceq [string]$row.Kind -and [string]$_.Operation -ceq 'assert'
            })
        Assert-Adoption ($entries.Count -eq 1) `
            "The ledger has $($entries.Count) assert entries for '$($row.Kind)'; exactly one was driven."
        if ($entries.Count -eq 1) {
            Assert-Adoption ([string]$entries[0].Producer -ceq [string]$row.Producer) `
                "The ledger attributes '$($row.Kind)' to '$($entries[0].Producer)' rather than '$($row.Producer)'."
        }
    }

    # -----------------------------------------------------------------------
    # 6. File contract adoption across all twelve kinds.
    # -----------------------------------------------------------------------
    $utf8Strict = [System.Text.UTF8Encoding]::new($false, $true)
    foreach ($row in $rows) {
        $payload = New-ReviewerStageAdoptionPayload -Row $row
        $artifactPath = Join-Path $sandbox "$($row.Stage).json"
        $written = Write-ReviewerStageArtifact -Path $artifactPath -Kind ([string]$row.Kind) `
            -Payload $payload -Depth 12 -Form 'compact' -StrictShape

        $bytes = [IO.File]::ReadAllBytes($artifactPath)
        Assert-Adoption ([int]$written.ByteLength -eq $bytes.Length) `
            "Stage '$($row.Stage)' reported $($written.ByteLength) bytes but published $($bytes.Length)."
        $digest = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
        Assert-Adoption ([string]$written.Sha256 -ceq $digest) `
            "Stage '$($row.Stage)' reported a digest that is not over the bytes it published."
        Assert-Adoption (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) `
            "Stage '$($row.Stage)' published a UTF-8 BOM."
        Assert-Adoption ($bytes[$bytes.Length - 1] -eq 0x0A) `
            "Stage '$($row.Stage)' did not terminate its artifact with a newline."
        $publishedText = $utf8Strict.GetString($bytes)
        Assert-Adoption (-not $publishedText.TrimEnd("`n").Contains("`n")) `
            "Stage '$($row.Stage)' declared the compact form but published line breaks."
        Assert-Adoption (@(Get-ChildItem -LiteralPath $sandbox -Filter '*.tmp' -File).Count -eq 0) `
            "Stage '$($row.Stage)' left a temporary file behind; publication is not atomic."

        $read = Read-ReviewerStageArtifact -Path $artifactPath -Kind ([string]$row.Kind)
        Assert-Adoption ([string]$read.Kind -ceq [string]$row.Kind) `
            "Stage '$($row.Stage)' read back as kind '$($read.Kind)'."
        Assert-Adoption ([int]$read.ContractVersion -eq 1 -and [int]$read.SourceVersion -eq 1 -and -not [bool]$read.Adapted) `
            "Stage '$($row.Stage)' round-tripped through an unexpected version or adapter."
        $slotValue = $read.Payload.PSObject.Properties[[string]$row.CollectionSlot].Value
        Assert-Adoption ($slotValue -is [System.Array] -and [int]@($slotValue).Count -eq 2) `
            "Stage '$($row.Stage)' lost its two-element census across the file contract."

        # Every declared field, and nothing else, survives the round trip.
        $registered = Get-ReviewerStageContract -Kind ([string]$row.Kind)
        $readNames = [string[]]@(@($read.Payload.PSObject.Properties) | ForEach-Object { [string]$_.Name })
        $expectedNames = [string[]]@([string[]]$registered.RequiredFields)
        Assert-Adoption ((($readNames | Sort-Object) -join ',') -ceq (($expectedNames | Sort-Object) -join ',')) `
            "Stage '$($row.Stage)' round-tripped fields '$($readNames -join ",")' rather than '$($expectedNames -join ",")'."
    }

    # A read-only inventory of everything published so far.
    $before = @(Get-ChildItem -LiteralPath $sandbox -File | Sort-Object Name | ForEach-Object {
            "$($_.Name):$($_.Length):$($_.LastWriteTimeUtc.Ticks)"
        })
    $inventory = Get-ReviewerStageArtifactInventory -Directory $sandbox
    $after = @(Get-ChildItem -LiteralPath $sandbox -File | Sort-Object Name | ForEach-Object {
            "$($_.Name):$($_.Length):$($_.LastWriteTimeUtc.Ticks)"
        })
    Assert-Adoption (($before -join '|') -ceq ($after -join '|')) `
        "The stage artifact inventory modified the directory it was asked to describe."
    Assert-Adoption ($inventory.Count -eq $rowCount) `
        "The inventory reported $($inventory.Count) artifacts for $($rowCount) published boundaries."
    foreach ($row in $rows) {
        $record = @($inventory | Where-Object { [string]$_.Kind -ceq [string]$row.Kind })
        Assert-Adoption ($record.Count -eq 1 -and [string]$record[0].Status -ceq 'envelope') `
            "The inventory did not identify the published '$($row.Kind)' artifact."
    }

    # -----------------------------------------------------------------------
    # 7. The fault matrix, applied to every stage kind.
    # -----------------------------------------------------------------------
    foreach ($row in $rows) {
        $kind = [string]$row.Kind
        $goodPath = Join-Path $sandbox "$($row.Stage).json"
        $goodBytes = [IO.File]::ReadAllBytes($goodPath)
        $goodText = $utf8Strict.GetString($goodBytes)
        $faultPath = Join-Path $sandbox "$($row.Stage).fault.json"

        $faults = [ordered]@{}
        $faults['bom'] = [byte[]]@(0xEF, 0xBB, 0xBF) + $goodBytes
        $faults['invalidUtf8'] = $goodBytes[0..($goodBytes.Length - 2)] + [byte[]]@(0xC3, 0x28, 0x0A)
        $faults['truncated'] = $goodBytes[0..($goodBytes.Length - 12)]
        $faults['stdoutPrologue'] = $utf8Strict.GetBytes("VERBOSE: preparing`n" + $goodText)
        $faults['stdoutEpilogue'] = $utf8Strict.GetBytes($goodText.TrimEnd("`n") + "`nDone.`n")
        $faults['scalarEnvelope'] = $utf8Strict.GetBytes("42`n")
        $faults['unknownEnvelopeField'] = $utf8Strict.GetBytes(
            $goodText.TrimEnd("`n").Insert(1, '"smuggled":true,') + "`n")
        $faults['missingEnvelopeField'] = $utf8Strict.GetBytes(
            ($goodText.TrimEnd("`n") -replace '"envelopeVersion":1,', '') + "`n")
        $faults['wrongScalarPayload'] = $utf8Strict.GetBytes(
            ($goodText.TrimEnd("`n") -replace '"payload":\{.*\}\}$', '"payload":"not-an-object"}') + "`n")
        $faults['kindClaimSwapped'] = $utf8Strict.GetBytes(
            ($goodText.TrimEnd("`n").Replace("`"kind`":`"$kind`"", '"kind":"reviewer.stage.impostor.v1"')) + "`n")

        foreach ($faultName in $faults.Keys) {
            [IO.File]::WriteAllBytes($faultPath, [byte[]]$faults[$faultName])
            Assert-AdoptionThrows -Action { Read-ReviewerStageArtifact -Path $faultPath -Kind $kind } `
                -Message "Stage '$($row.Stage)' read a '$faultName' artifact instead of failing closed."
        }
        Remove-Item -LiteralPath $faultPath -Force
    }

    # -----------------------------------------------------------------------
    # 8. Reader compatibility with already-published bytes, pinned literally.
    # -----------------------------------------------------------------------
    # These bytes are what the source boundary published when it was adopted. A
    # reader change that can no longer read them is a compatibility break for
    # every artifact already on disk, so the exact text is pinned here rather
    # than regenerated from the writer it is supposed to be independent of.
    $pinnedSource = '{"envelopeVersion":1,"kind":"reviewer.stage.source.v1","contractVersion":1,"form":"compact","depth":12,"payload":{"changedPaths":["alpha","beta"]}}' + "`n"
    $pinnedPath = Join-Path $sandbox 'pinned-source.json'
    [IO.File]::WriteAllBytes($pinnedPath, $utf8Strict.GetBytes($pinnedSource))
    $pinnedRead = Read-ReviewerStageArtifact -Path $pinnedPath -Kind 'reviewer.stage.source.v1'
    Assert-Adoption ([int]@($pinnedRead.Payload.changedPaths).Count -eq 2) `
        "The reader no longer reads an already-published source stage artifact."
    $rewritten = Write-ReviewerStageArtifact -Path (Join-Path $sandbox 'pinned-rewrite.json') `
        -Kind 'reviewer.stage.source.v1' -Payload ([ordered]@{ changedPaths = [object[]]@('alpha', 'beta') }) `
        -Depth 12 -Form 'compact'
    $rewrittenText = $utf8Strict.GetString([IO.File]::ReadAllBytes((Join-Path $sandbox 'pinned-rewrite.json')))
    Assert-Adoption ($rewrittenText -ceq $pinnedSource) `
        "The writer no longer reproduces the pinned source stage bytes byte for byte."
    Assert-Adoption ([string]$rewritten.Sha256 -ceq [string]$pinnedRead.Sha256) `
        "The writer's digest and the reader's digest disagree about identical bytes."

    # An empty census must survive the file contract as an empty census, not as
    # an absent one - this is the collapse the whole corpus is about.
    $emptyPath = Join-Path $sandbox 'empty-source.json'
    $null = Write-ReviewerStageArtifact -Path $emptyPath -Kind 'reviewer.stage.source.v1' `
        -Payload (New-ReviewerSourceStageContract -ChangedPaths ([object[]]@())) -Depth 12 -Form 'compact'
    $emptyRead = Read-ReviewerStageArtifact -Path $emptyPath -Kind 'reviewer.stage.source.v1'
    Assert-Adoption ($null -ne $emptyRead.Payload.PSObject.Properties['changedPaths']) `
        "An empty source census read back as an absent field."
    Assert-Adoption ([int]@($emptyRead.Payload.changedPaths).Count -eq 0) `
        "An empty source census did not read back as empty."

    # -----------------------------------------------------------------------
    # 9. Synthetic, no-model coordinator preparation through run-set-ready.
    # -----------------------------------------------------------------------
    # Every boundary that has a callable pure producer is driven through the REAL
    # producer here, in run order, on one synthetic change set. Nothing below
    # opens a session, calls a model, or writes outside the sandbox.
    Clear-ReviewerStageContractLedger

    # capture: the live producer authenticates a sealed package from disk, which
    # is not reachable without a capture. Its contract is driven through the same
    # builder the producer calls, and the residual is declared rather than hidden.
    $capturePrepared = New-ReviewerCaptureStageContract `
        -PackageFiles ([object[]]@('capture-core.json', 'result-marker.txt')) `
        -PackageDirectories ([object[]]@()) `
        -AttemptMarkerStatuses ([object[]]@('success'))
    Assert-Adoption ([int]@($capturePrepared.packageFiles).Count -eq 2) `
        "The synthetic capture preparation lost its package census."

    $sourcePrepared = Get-ReviewerSourceRawChangedPaths -Response ([pscustomobject]@{
            changes = @(
                [pscustomobject]@{ item = [pscustomobject]@{ path = '/src/one.ps1'; isFolder = $false } },
                [pscustomobject]@{ item = [pscustomobject]@{ path = '/src/two.ps1'; isFolder = $false } })
        })
    Assert-Adoption ([int]@($sourcePrepared).Count -eq 2) `
        "The synthetic source preparation did not publish both changed paths."

    $snapshotPrepared = Get-ReviewerCorpusSealSpanEvidence -Where 'synthetic span evidence' -Evidence @(
        [pscustomobject]@{ path = '/src/one.ps1'; hunks = @([pscustomobject]@{ newStart = 1; newCount = 4 }) },
        [pscustomobject]@{ path = '/src/two.ps1'; hunks = @([pscustomobject]@{ newStart = 2; newCount = 1 }) })
    Assert-Adoption ([int](@($snapshotPrepared.Keys)).Count -eq 2) `
        "The synthetic snapshot preparation did not publish both span censuses."

    $corpusPrepared = Get-ReviewerEvalGroundTruth -Labels @(
        [pscustomobject]@{ labelerId = 'a'; issueIds = @('i1'); decision = 'block' },
        [pscustomobject]@{ labelerId = 'b'; issueIds = @('i1'); decision = 'block' })
    Assert-Adoption ([string]$corpusPrepared.resolution -ceq 'concordant') `
        "The synthetic corpus preparation did not reconcile two concordant labels."

    $blindPrepared = Expand-ReviewerConventionSpecialistConstructIds -Text 'mi0-mi2,dc0'
    Assert-Adoption ([bool]$blindPrepared.Ok -and [int]@($blindPrepared.Ids).Count -eq 4) `
        "The synthetic blind-results preparation did not expand its construct range."

    $unionCandidates = @(
        [pscustomobject]@{ candidateId = 'c1'; candidateHash = 'h1'; originKind = 'generalist'; originModel = 'model-a'; anchorKind = 'changedFile'; filePath = 'src/one.ps1'; title = 'first'; severity = 'important' },
        [pscustomobject]@{ candidateId = 'c2'; candidateHash = 'h2'; originKind = 'generalist'; originModel = 'model-b'; anchorKind = 'changedFile'; filePath = 'src/two.ps1'; title = 'second'; severity = 'suggestion' })
    $unionPrepared = Get-ReviewerVerificationClusters -Candidates $unionCandidates
    Assert-Adoption ([int]@($unionPrepared).Count -ge 1) `
        "The synthetic candidate-union preparation produced no clusters."

    $fingerprintPrepared = Get-ReviewerGateApprovalCoverageKey `
        -Decision ([pscustomobject]@{ prId = 7; sourceCommit = 'ABC123'; gateHumanPromotableCount = 0; gateImportantOrHigherCount = 0; gateImportantOrHigherKeys = @() }) `
        -ConfirmedImportantOrHigherKeys @()
    Assert-Adoption ($fingerprintPrepared -clike 'approval:*') `
        "The synthetic fingerprints preparation did not mint an approval coverage key."

    $planPrepared = Get-ReviewerChangedConstructs -Files @(
        @{ Path = 'src/one.ps1'; Lines = @('function Get-One {', '    Write-Output 1', '}'); ChangedLines = @(1, 2, 3) })
    Assert-Adoption ($planPrepared.Files -is [System.Array] -and $planPrepared.PartiallyUnderstoodFiles -is [System.Array]) `
        "The synthetic specialist-plan preparation lost one of its six censuses."

    $assignmentPrepared = Get-ReviewerVerificationAssignments -Clusters $unionPrepared `
        -GeneralistModels ([string[]]@('model-a', 'model-b'))
    Assert-Adoption ([int]@($assignmentPrepared).Count -eq (2 * @($unionCandidates).Count)) `
        "The synthetic verifier-assignment preparation did not plan two verifiers per candidate."

    $verdictPrepared = Get-ReviewerVerificationAcceptedConventionCandidates `
        -ConventionCandidates @() -Decisions @() -Clusters $unionPrepared
    Assert-Adoption ([int]@($verdictPrepared).Count -eq 0) `
        "The synthetic verdict preparation did not publish an empty acceptance as an empty set."

    $reconciliationPrepared = Get-ReviewerRunReconciliationDifference -Left @('c1', 'c2') -Right @('c2')
    Assert-Adoption ([int]@($reconciliationPrepared.OnlyLeft).Count -eq 1 -and
        [int]@($reconciliationPrepared.OnlyRight).Count -eq 0) `
        "The synthetic reconciliation preparation did not publish both difference censuses."

    $deliveryPrepared = Select-ReviewerGateSubset `
        -Approved @([pscustomobject]@{ candidateHash = 'h1'; path = 'src/one.ps1'; line = 1; severity = 'important' }) `
        -Allowed @([pscustomobject]@{ candidateHash = 'h1'; path = 'src/one.ps1'; line = 1; severity = 'important' })
    Assert-Adoption ($deliveryPrepared -is [System.Array] -and [int]@($deliveryPrepared).Count -eq 1) `
        "The synthetic delivery-decision preparation did not keep its allowed entry."

    $runSetLedger = Get-ReviewerStageContractLedger
    $runSetKinds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($entry in $runSetLedger) {
        if ([string]$entry.Operation -ceq 'assert') { [void]$runSetKinds.Add([string]$entry.Kind) }
    }
    foreach ($row in $rows) {
        Assert-Adoption ($runSetKinds.Contains([string]$row.Kind)) `
            "The synthetic run-set-ready preparation never reached the '$($row.Kind)' boundary."
    }
    Assert-Adoption ($runSetKinds.Count -eq 12) `
        "The synthetic preparation reached $($runSetKinds.Count) of twelve boundaries."

    # The preparation is a preparation: it published nothing outside the sandbox
    # and left the sandbox itself unchanged by the run-set stage.
    Assert-Adoption (@(Get-ChildItem -LiteralPath $sandbox -Filter '*.tmp' -File).Count -eq 0) `
        "The synthetic preparation left a temporary artifact behind."
}
finally {
    if (Test-Path -LiteralPath $sandbox) {
        Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($failures.Count -eq 0) {
    Write-Host "PASS - $checks stage producer contract adoption checks." -ForegroundColor Green
    exit 0
}
Write-Host "FAIL - $($failures.Count) of $checks stage producer contract adoption checks failed:" -ForegroundColor Red
foreach ($failure in $failures) { Write-Host "  - $failure" -ForegroundColor Red }
exit 1
