#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Finds selected PowerShell empty-output-to-null hazards with the PowerShell AST.

.DESCRIPTION
    Reports deliberately narrow rule classes.

    Empty-output-to-null hazards:
      PSEN001 - a bare command/pipeline flows into a typed array assignment or a
                mandatory typed-array parameter declared in the analyzed files;
      PSEN002 - an array subexpression contains an explicit $null without a
                recognizable null-removing Where-Object filter; and
      PSEN003 - Measure-Object -Sum is dereferenced through .Sum without a
                recognized default or non-empty input guard.

    Boundary-hardening hazards (a collection, a closure, or a serialized
    contract changes shape as it crosses a call, capture, or file boundary):
      PSEN004 - a function returns a locally constructed .NET collection bare,
                so PowerShell enumerates it and an empty collection becomes
                $null at the call site;
      PSEN005 - .Count/.Length or an index is taken directly on an
                unconstrained parenthesized command or pipeline expression;
      PSEN006 - a script block references an unqualified variable that this
                file also assigns at script scope, so the captured value
                depends on ambient state rather than explicit capture;
      PSEN007 - ConvertTo-Json is called without an explicit -Depth, so the
                serialized contract depth is whatever the host defaults to;
      PSEN008 - a ConvertTo-Json result is written to a file without an
                explicit -Compress decision, leaving the on-disk form of a
                contract implicit; and
      PSEN009 - a non-preserved command/statement result is assigned and later
                indexed or counted, so a single result flattens to a scalar; and
      PSEN010 - a .GetNewClosure() script block calls a function defined in the
                analyzed files by name, but GetNewClosure captures variables,
                not function definitions, so the call resolves against whatever
                scope later invokes the closure; and
      PSEN011 - @(...) wraps a call to a function that deliberately protects its
                collection return, which nests that return as a single element
                instead of flattening it.

    This is a heuristic prevention aid, not a PowerShell type or control-flow
    prover. Use -OutputFormat Json for CI or measurement consumers.

.EXAMPLE
    ./tools/Find-PowerShellEmptyNullHazard.ps1 -Path ./src -Recurse -OutputFormat Json

.EXAMPLE
    ./tools/Find-PowerShellEmptyNullHazard.ps1 -Path ./src -Recurse -RuleId PSEN004, PSEN006
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string[]]$Path,
    [switch]$Recurse,
    [ValidateSet('Object', 'Json')][string]$OutputFormat = 'Object',
    [ValidateSet('PSEN001', 'PSEN002', 'PSEN003', 'PSEN004', 'PSEN005',
        'PSEN006', 'PSEN007', 'PSEN008', 'PSEN009', 'PSEN010', 'PSEN011')][string[]]$RuleId
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Get-InputFiles {
    param([string[]]$InputPath, [bool]$Recursive)

    foreach ($candidate in $InputPath) {
        $resolved = Resolve-Path -LiteralPath $candidate
        foreach ($item in $resolved) {
            if (Test-Path -LiteralPath $item.Path -PathType Leaf) {
                if ([IO.Path]::GetExtension($item.Path) -in '.ps1', '.psm1', '.psd1') {
                    Get-Item -LiteralPath $item.Path
                }
                continue
            }
            Get-ChildItem -LiteralPath $item.Path -File -Recurse:$Recursive |
                Where-Object Extension -in '.ps1', '.psm1', '.psd1'
        }
    }
}

function Test-MandatoryAttribute {
    param([Management.Automation.Language.ParameterAst]$Parameter)

    foreach ($attribute in $Parameter.Attributes) {
        if ($attribute -isnot [Management.Automation.Language.AttributeAst] -or
            $attribute.TypeName.Name -notin 'Parameter', 'ParameterAttribute') {
            continue
        }
        foreach ($argument in $attribute.NamedArguments) {
            if ($argument.ArgumentName -ine 'Mandatory') { continue }
            if ($argument.ExpressionOmitted) { return $true }
            if ($argument.Argument -is [Management.Automation.Language.VariableExpressionAst] -and
                $argument.Argument.VariablePath.UserPath -ieq 'true') {
                return $true
            }
            if ($argument.Argument -is [Management.Automation.Language.ConstantExpressionAst] -and
                [bool]$argument.Argument.Value) {
                return $true
            }
        }
    }
    return $false
}

function Test-ExplicitArrayPreservation {
    param([Management.Automation.Language.Ast]$Ast)

    $current = $Ast
    while ($current -is [Management.Automation.Language.ParenExpressionAst] -or
        $current -is [Management.Automation.Language.CommandExpressionAst]) {
        if ($current -is [Management.Automation.Language.ParenExpressionAst]) {
            $current = $current.Pipeline
        }
        else {
            $current = $current.Expression
        }
    }
    if ($current -is [Management.Automation.Language.ArrayExpressionAst] -or
        $current -is [Management.Automation.Language.ArrayLiteralAst]) {
        return $true
    }
    if ($current -is [Management.Automation.Language.ConvertExpressionAst]) {
        $type = $current.Type.TypeName.GetReflectionType()
        return $null -ne $type -and $type.IsArray
    }
    return $false
}

function Test-ContainsCommandOutput {
    param([Management.Automation.Language.Ast]$Ast)

    return @($Ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.CommandAst]
            }, $true)).Count -gt 0
}

function Test-ArrayTypeConstraint {
    param([Management.Automation.Language.Ast]$Ast)

    if ($Ast -isnot [Management.Automation.Language.ConvertExpressionAst]) { return $false }
    $type = $Ast.Type.TypeName.GetReflectionType()
    return $null -ne $type -and $type.IsArray
}

function Test-NullRemovingFilter {
    param([Management.Automation.Language.ArrayExpressionAst]$Array)

    $whereCommands = @($Array.FindAll({
                param($node)
                $node -is [Management.Automation.Language.CommandAst] -and
                $node.GetCommandName() -in 'Where-Object', 'where', '?'
            }, $true))
    foreach ($command in $whereCommands) {
        $hasNotEqual = @($command.FindAll({
                    param($node)
                    $node -is [Management.Automation.Language.BinaryExpressionAst] -and
                    $node.Operator -in [Management.Automation.Language.TokenKind]::Ine,
                    [Management.Automation.Language.TokenKind]::Cne -and
                    @($node.FindAll({
                                param($part)
                                $part -is [Management.Automation.Language.VariableExpressionAst] -and
                                $part.VariablePath.UserPath -ieq 'null'
                            }, $true)).Count -gt 0
                }, $true)).Count -gt 0
        if ($hasNotEqual) { return $true }
    }
    return $false
}

function Get-MeasureInputVariable {
    param([Management.Automation.Language.MemberExpressionAst]$Member)

    $variables = @($Member.Expression.FindAll({
                param($node)
                $node -is [Management.Automation.Language.VariableExpressionAst] -and
                $node.VariablePath.UserPath -notin '_', 'null', 'true', 'false'
            }, $true))
    if ($variables.Count -eq 0) { return $null }
    return [string]$variables[0].VariablePath.UserPath
}

function Test-CountComparison {
    param(
        [Management.Automation.Language.Ast]$Condition,
        [string]$Variable,
        [ValidateSet('NonEmpty', 'Empty')][string]$Mode
    )

    $comparison = $Condition
    while ($comparison -is [Management.Automation.Language.PipelineAst] -or
        $comparison -is [Management.Automation.Language.CommandExpressionAst] -or
        $comparison -is [Management.Automation.Language.ParenExpressionAst]) {
        if ($comparison -is [Management.Automation.Language.PipelineAst]) {
            if (@($comparison.PipelineElements).Count -ne 1 -or
                $comparison.PipelineElements[0] -isnot [Management.Automation.Language.CommandExpressionAst]) {
                return $false
            }
            $comparison = $comparison.PipelineElements[0].Expression
        }
        elseif ($comparison -is [Management.Automation.Language.CommandExpressionAst]) {
            $comparison = $comparison.Expression
        }
        else {
            $comparison = $comparison.Pipeline
        }
    }
    if ($Mode -eq 'NonEmpty' -and
        $comparison -is [Management.Automation.Language.BinaryExpressionAst] -and
        $comparison.Operator -in [Management.Automation.Language.TokenKind]::And,
        [Management.Automation.Language.TokenKind]::AndAnd) {
        # If either conjunct proves non-empty, the complete conjunction does too.
        return (Test-CountComparison -Condition $comparison.Left -Variable $Variable -Mode $Mode) -or
            (Test-CountComparison -Condition $comparison.Right -Variable $Variable -Mode $Mode)
    }
    if ($comparison -isnot [Management.Automation.Language.BinaryExpressionAst] -or
        $comparison.Left -isnot [Management.Automation.Language.MemberExpressionAst] -or
        $comparison.Left.Expression -isnot [Management.Automation.Language.VariableExpressionAst] -or
        $comparison.Left.Expression.VariablePath.UserPath -ine $Variable -or
        $comparison.Left.Member -isnot [Management.Automation.Language.StringConstantExpressionAst] -or
        [string]$comparison.Left.Member.Value -ine 'Count' -or
        $comparison.Right -isnot [Management.Automation.Language.ConstantExpressionAst] -or
        $comparison.Right.Value -isnot [ValueType]) {
        return $false
    }
    $number = [double]$comparison.Right.Value
    if ($Mode -eq 'NonEmpty') {
        return (($comparison.Operator -in [Management.Automation.Language.TokenKind]::Igt,
                    [Management.Automation.Language.TokenKind]::Cgt -and $number -ge 0) -or
            ($comparison.Operator -in [Management.Automation.Language.TokenKind]::Ige,
                    [Management.Automation.Language.TokenKind]::Cge -and $number -ge 1) -or
            ($comparison.Operator -in [Management.Automation.Language.TokenKind]::Ine,
                    [Management.Automation.Language.TokenKind]::Cne -and $number -eq 0))
    }
    return $comparison.Operator -in [Management.Automation.Language.TokenKind]::Ieq,
    [Management.Automation.Language.TokenKind]::Ceq -and $number -eq 0
}

function Test-MeasureDefaulted {
    param([Management.Automation.Language.MemberExpressionAst]$Member)

    $current = [Management.Automation.Language.Ast]$Member
    while ($null -ne $current.Parent -and
        $current.Parent -isnot [Management.Automation.Language.StatementBlockAst] -and
        $current.Parent -isnot [Management.Automation.Language.NamedBlockAst]) {
        $parent = $current.Parent
        if ($parent -is [Management.Automation.Language.BinaryExpressionAst] -and
            $parent.Operator -eq [Management.Automation.Language.TokenKind]::QuestionQuestion -and
            $parent.Left.Extent.StartOffset -le $Member.Extent.StartOffset -and
            $parent.Left.Extent.EndOffset -ge $Member.Extent.EndOffset) {
            return $true
        }
        $current = $parent
    }
    return $false
}

function Test-MeasureGuarded {
    param(
        [Management.Automation.Language.MemberExpressionAst]$Member,
        [string]$Variable
    )

    if ([string]::IsNullOrWhiteSpace($Variable)) { return $false }

    $child = [Management.Automation.Language.Ast]$Member
    $ancestor = $Member.Parent
    while ($null -ne $ancestor) {
        if ($ancestor -is [Management.Automation.Language.IfStatementAst]) {
            foreach ($clause in $ancestor.Clauses) {
                if ($child.Extent.StartOffset -ge $clause.Item2.Extent.StartOffset -and
                    $child.Extent.EndOffset -le $clause.Item2.Extent.EndOffset -and
                    (Test-CountComparison -Condition $clause.Item1 -Variable $Variable -Mode NonEmpty)) {
                    return $true
                }
            }
        }
        $child = $ancestor
        $ancestor = $ancestor.Parent
    }

    $statement = [Management.Automation.Language.Ast]$Member
    while ($null -ne $statement.Parent -and
        $statement.Parent -isnot [Management.Automation.Language.StatementBlockAst] -and
        $statement.Parent -isnot [Management.Automation.Language.NamedBlockAst]) {
        $statement = $statement.Parent
    }
    if ($null -eq $statement.Parent) { return $false }
    foreach ($prior in $statement.Parent.Statements) {
        if ($prior.Extent.StartOffset -ge $statement.Extent.StartOffset -or
            $prior -isnot [Management.Automation.Language.IfStatementAst]) {
            continue
        }
        foreach ($clause in $prior.Clauses) {
            $terminates = @($clause.Item2.Statements | Where-Object {
                    $_ -is [Management.Automation.Language.ReturnStatementAst] -or
                    $_ -is [Management.Automation.Language.ThrowStatementAst]
                }).Count -gt 0
            $interveningAssignment = @($statement.Parent.FindAll({
                        param($node)
                        if ($node -isnot [Management.Automation.Language.AssignmentStatementAst] -or
                            $node.Extent.StartOffset -le $prior.Extent.EndOffset -or
                            $node.Extent.EndOffset -ge $statement.Extent.StartOffset) {
                            return $false
                        }
                        $left = $node.Left
                        if ($left -is [Management.Automation.Language.ConvertExpressionAst]) {
                            $left = $left.Child
                        }
                        return ($left -is [Management.Automation.Language.VariableExpressionAst] -and
                            $left.VariablePath.UserPath -ieq $Variable)
                    }, $true)).Count -gt 0
            if ($terminates -and
                -not $interveningAssignment -and
                (Test-CountComparison -Condition $clause.Item1 -Variable $Variable -Mode Empty)) {
                return $true
            }
        }
    }
    return $false
}

function Get-CollectionReturnProtection {
    <#
    .SYNOPSIS
        Classifies how a function hands a collection back to its caller.

    .DESCRIPTION
        Write-Output -NoEnumerate and a unary-comma return both hand the caller
        the collection itself instead of its elements. Two different questions
        follow from that, and they need different answers:

        Any   - at least one exit is protected, so @(f) nests rather than
                flattens on that path. Wrapping such a call is a hazard even
                when other exits enumerate (PSEN011).
        All   - every exit is protected or provably scalar, so assigning the
                result cannot collapse. Only this earns an exemption from the
                assignment rules (PSEN005/PSEN009). A function with one bare
                collection exit and one protected exit is exactly the escape
                shape those rules exist to catch, so it earns nothing.
    #>
    param([Management.Automation.Language.FunctionDefinitionAst]$Function)

    $protectedExits = 0
    $unprotectedExits = 0
    foreach ($command in $Function.Body.FindAll({
                param($node)
                $node -is [Management.Automation.Language.CommandAst]
            }, $true)) {
        if ([string]$command.GetCommandName() -ine 'Write-Output') { continue }
        if (Test-CommandParameterPresent -Command $command -NamePrefix 'NoEnum') { $protectedExits++ }
    }
    foreach ($return in $Function.Body.FindAll({
                param($node)
                $node -is [Management.Automation.Language.ReturnStatementAst]
            }, $true)) {
        if ($null -eq $return.Pipeline) { continue }
        $pipeline = $return.Pipeline
        if ($pipeline -isnot [Management.Automation.Language.PipelineAst]) { continue }
        $elements = @($pipeline.PipelineElements)
        if ($elements.Count -ne 1) { continue }
        $element = $elements[0]
        if ($element -isnot [Management.Automation.Language.CommandExpressionAst]) {
            # "return f x" hands the caller whatever the command emits.
            $unprotectedExits++
            continue
        }
        if (Test-ProtectedReturnExpression -Expression $element.Expression) {
            $protectedExits++
            continue
        }
        if (-not (Test-ScalarReturnExpression -Expression $element.Expression)) { $unprotectedExits++ }
    }
    return [pscustomobject]@{
        Any = ($protectedExits -gt 0)
        All = ($protectedExits -gt 0 -and $unprotectedExits -eq 0)
    }
}

function Test-ProtectedReturnExpression {
    <#
    .SYNOPSIS
        True for the unary-comma return form, which preserves the collection.
    #>
    param([Management.Automation.Language.Ast]$Expression)

    # ", $x" parses as a one-element array literal whose extent starts with
    # the comma; that is the protected-return form, unlike "@(1, 2)".
    if ($Expression -is [Management.Automation.Language.ArrayLiteralAst] -and
        @($Expression.Elements).Count -eq 1 -and
        ([string]$Expression.Extent.Text).TrimStart().StartsWith(',')) {
        return $true
    }
    if ($Expression -is [Management.Automation.Language.UnaryExpressionAst] -and
        $Expression.TokenKind -eq [Management.Automation.Language.TokenKind]::Comma) {
        return $true
    }
    return $false
}

function Test-ScalarReturnExpression {
    <#
    .SYNOPSIS
        True when a return expression cannot carry a collection, so it neither
        protects nor breaks the caller's flattening assumption.

    .DESCRIPTION
        Deliberately narrow: anything not recognised here is treated as a
        collection-bearing exit, which withdraws the exemption rather than
        granting one that was not earned.
    #>
    param([Management.Automation.Language.Ast]$Expression)

    if ($Expression -is [Management.Automation.Language.ConstantExpressionAst]) { return $true }
    if ($Expression -is [Management.Automation.Language.StringConstantExpressionAst]) { return $true }
    if ($Expression -is [Management.Automation.Language.ExpandableStringExpressionAst]) { return $true }
    if ($Expression -is [Management.Automation.Language.HashtableAst]) { return $true }
    if ($Expression -is [Management.Automation.Language.ScriptBlockExpressionAst]) { return $true }
    if ($Expression -is [Management.Automation.Language.VariableExpressionAst]) {
        $name = [string]$Expression.VariablePath.UserPath
        return ($name -iin @('null', 'true', 'false'))
    }
    if ($Expression -is [Management.Automation.Language.ConvertExpressionAst]) {
        $typeName = [string]$Expression.Type.TypeName.FullName
        if ($typeName -match '\[\s*\]$') { return $false }
        return $true
    }
    return $false
}

function Test-ProtectedReturnSource {
    <#
    .SYNOPSIS
        True when an expression is exactly one call to a function that protects
        its own collection return.
    #>
    param(
        [Management.Automation.Language.Ast]$Ast,
        [System.Collections.Generic.HashSet[string]]$ProtectedNames
    )

    if ($null -eq $ProtectedNames -or $ProtectedNames.Count -eq 0) { return $false }
    $current = $Ast
    while ($current -is [Management.Automation.Language.ParenExpressionAst]) {
        $current = $current.Pipeline
    }
    if ($current -isnot [Management.Automation.Language.PipelineAst]) { return $false }
    $elements = @($current.PipelineElements)
    if ($elements.Count -ne 1) { return $false }
    $command = $elements[0]
    if ($command -isnot [Management.Automation.Language.CommandAst]) { return $false }
    $commandName = $command.GetCommandName()
    if ([string]::IsNullOrWhiteSpace($commandName)) { return $false }
    return $ProtectedNames.Contains($commandName)
}

$script:EnumeratingCollectionTypePattern =
'(^|\.)(List|HashSet|SortedSet|ArrayList|Queue|Stack|Collection|BlockingCollection|ConcurrentBag|ConcurrentQueue|ConcurrentStack)(`\d+)?(\[|$)'

function Get-VariableName {
    param([System.Management.Automation.VariablePath]$VariablePath)

    $userPath = [string]$VariablePath.UserPath
    $separator = $userPath.LastIndexOf(':')
    if ($separator -lt 0) { return $userPath }
    return $userPath.Substring($separator + 1)
}

function Test-EnumeratingCollectionTypeName {
    param([AllowEmptyString()][string]$TypeName)

    if ([string]::IsNullOrWhiteSpace($TypeName)) { return $false }
    return $TypeName -match $script:EnumeratingCollectionTypePattern
}

# A locally constructed List/HashSet/ArrayList is the shape that silently
# becomes $null when it is empty and the function returns it bare, because the
# return enumerates it into zero pipeline objects.
function Test-EnumeratingCollectionConstruction {
    param([Management.Automation.Language.Ast]$Ast)

    $current = $Ast
    while ($current -is [Management.Automation.Language.PipelineAst] -or
        $current -is [Management.Automation.Language.CommandExpressionAst] -or
        $current -is [Management.Automation.Language.ParenExpressionAst]) {
        if ($current -is [Management.Automation.Language.PipelineAst]) {
            if (@($current.PipelineElements).Count -ne 1) { return $false }
            $current = $current.PipelineElements[0]
        }
        elseif ($current -is [Management.Automation.Language.CommandExpressionAst]) {
            $current = $current.Expression
        }
        else {
            $current = $current.Pipeline
        }
    }
    if ($current -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
        $current.Expression -is [Management.Automation.Language.TypeExpressionAst] -and
        $current.Member -is [Management.Automation.Language.StringConstantExpressionAst] -and
        [string]$current.Member.Value -ieq 'new') {
        return Test-EnumeratingCollectionTypeName -TypeName $current.Expression.TypeName.FullName
    }
    if ($current -is [Management.Automation.Language.CommandAst] -and
        $current.GetCommandName() -in 'New-Object', 'new-object') {
        foreach ($element in @($current.CommandElements)) {
            if ($element -is [Management.Automation.Language.StringConstantExpressionAst] -and
                (Test-EnumeratingCollectionTypeName -TypeName ([string]$element.Value))) {
                return $true
            }
        }
    }
    return $false
}

function Get-BareVariableName {
    param([Management.Automation.Language.Ast]$Ast)

    $current = $Ast
    while ($current -is [Management.Automation.Language.PipelineAst] -or
        $current -is [Management.Automation.Language.CommandExpressionAst] -or
        $current -is [Management.Automation.Language.ParenExpressionAst]) {
        if ($current -is [Management.Automation.Language.PipelineAst]) {
            if (@($current.PipelineElements).Count -ne 1) { return $null }
            $current = $current.PipelineElements[0]
        }
        elseif ($current -is [Management.Automation.Language.CommandExpressionAst]) {
            $current = $current.Expression
        }
        else {
            $current = $current.Pipeline
        }
    }
    if ($current -isnot [Management.Automation.Language.VariableExpressionAst]) { return $null }
    return [string]$current.VariablePath.UserPath
}

function Test-UnwrappedArrayPreservation {
    param([Management.Automation.Language.Ast]$Ast)

    $current = $Ast
    while ($current -is [Management.Automation.Language.PipelineAst] -or
        $current -is [Management.Automation.Language.CommandExpressionAst] -or
        $current -is [Management.Automation.Language.ParenExpressionAst]) {
        if ($current -is [Management.Automation.Language.PipelineAst]) {
            if (@($current.PipelineElements).Count -ne 1) { return $false }
            $current = $current.PipelineElements[0]
        }
        elseif ($current -is [Management.Automation.Language.CommandExpressionAst]) {
            $current = $current.Expression
        }
        else {
            $current = $current.Pipeline
        }
    }
    return (Test-ExplicitArrayPreservation -Ast $current)
}

function Get-UnconstrainedCommandSource {
    param(
        [Management.Automation.Language.Ast]$Ast,
        [System.Collections.Generic.HashSet[string]]$ProtectedNames
    )

    if ($Ast -is [Management.Automation.Language.ParenExpressionAst]) {
        if ((Test-UnwrappedArrayPreservation -Ast $Ast.Pipeline)) { return $null }
        # A call to a function that emits its collection without enumerating it has a
        # known cardinality at the call site, so counting or indexing it is safe.
        if ((Test-ProtectedReturnSource -Ast $Ast.Pipeline -ProtectedNames $ProtectedNames)) { return $null }
        if (-not (Test-ContainsCommandOutput -Ast $Ast.Pipeline)) { return $null }
        return $Ast
    }
    if ($Ast -is [Management.Automation.Language.SubExpressionAst]) {
        $statements = @($Ast.SubExpression.Statements)
        if ($statements.Count -eq 1 -and (Test-UnwrappedArrayPreservation -Ast $statements[0])) { return $null }
        if ($statements.Count -eq 1 -and (Test-ProtectedReturnSource -Ast $statements[0] -ProtectedNames $ProtectedNames)) { return $null }
        if (-not (Test-ContainsCommandOutput -Ast $Ast.SubExpression)) { return $null }
        return $Ast
    }
    return $null
}

function Get-ScriptScopedNames {
    param([Management.Automation.Language.Ast]$Ast)

    $names = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)
    foreach ($assignment in $Ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.AssignmentStatementAst]
            }, $true)) {
        $left = $assignment.Left
        if ($left -is [Management.Automation.Language.ConvertExpressionAst]) { $left = $left.Child }
        if ($left -is [Management.Automation.Language.VariableExpressionAst] -and
            $left.VariablePath.IsScript) {
            [void]$names.Add((Get-VariableName -VariablePath $left.VariablePath))
        }
    }
    Write-Output -NoEnumerate $names
}

function Get-ScriptBlockLocalNames {
    param([Management.Automation.Language.ScriptBlockAst]$ScriptBlock)

    $names = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)
    if ($null -ne $ScriptBlock.ParamBlock) {
        foreach ($parameter in @($ScriptBlock.ParamBlock.Parameters)) {
            [void]$names.Add((Get-VariableName -VariablePath $parameter.Name.VariablePath))
        }
    }
    foreach ($assignment in $ScriptBlock.FindAll({
                param($node)
                $node -is [Management.Automation.Language.AssignmentStatementAst]
            }, $true)) {
        $left = $assignment.Left
        if ($left -is [Management.Automation.Language.ConvertExpressionAst]) { $left = $left.Child }
        if ($left -is [Management.Automation.Language.VariableExpressionAst]) {
            [void]$names.Add((Get-VariableName -VariablePath $left.VariablePath))
        }
    }
    foreach ($loop in $ScriptBlock.FindAll({
                param($node)
                $node -is [Management.Automation.Language.ForEachStatementAst]
            }, $true)) {
        [void]$names.Add((Get-VariableName -VariablePath $loop.Variable.VariablePath))
    }
    Write-Output -NoEnumerate $names
}

function Test-CommandParameterPresent {
    [CmdletBinding()]
    param(
        [Management.Automation.Language.CommandAst]$Command,
        [string]$NamePrefix
    )

    if ([string]::IsNullOrEmpty($NamePrefix)) {
        throw "Test-CommandParameterPresent requires a non-empty -NamePrefix."
    }
    foreach ($element in @($Command.CommandElements)) {
        if ($element -is [Management.Automation.Language.CommandParameterAst] -and
            ([string]$element.ParameterName).StartsWith($NamePrefix, [StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    return $false
}

$script:ContractWriteCommands = @('Set-Content', 'Out-File', 'Add-Content')
$script:ContractWriteMembers = @('WriteAllText', 'AppendAllText', 'WriteAllLines', 'WriteAllBytes')

function Test-ContractWriteContext {
    param([Management.Automation.Language.Ast]$Ast)

    $statement = $Ast
    while ($null -ne $statement.Parent -and
        $statement.Parent -isnot [Management.Automation.Language.StatementBlockAst] -and
        $statement.Parent -isnot [Management.Automation.Language.NamedBlockAst]) {
        $statement = $statement.Parent
    }
    return @($statement.FindAll({
                param($node)
                ($node -is [Management.Automation.Language.CommandAst] -and
                $node.GetCommandName() -in $script:ContractWriteCommands) -or
                ($node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
                $node.Member -is [Management.Automation.Language.StringConstantExpressionAst] -and
                [string]$node.Member.Value -in $script:ContractWriteMembers)
            }, $true)).Count -gt 0
}

function New-Finding {
    param(
        [string]$RuleId,
        [string]$Message,
        [string]$File,
        [Management.Automation.Language.Ast]$Ast
    )

    # Normalize before truncating: a 240-character cut applied to raw text lands
    # at a different point under CRLF than under LF, which would make the
    # checked-in fingerprint a property of the clone rather than of the code.
    $snippet = ([string]$Ast.Extent.Text -replace '\s+', ' ').Trim()
    if ($snippet.Length -gt 240) { $snippet = $snippet.Substring(0, 240) + '...' }
    [pscustomobject][ordered]@{
        RuleId = $RuleId
        File = $File
        Line = $Ast.Extent.StartLineNumber
        Column = $Ast.Extent.StartColumnNumber
        Message = $Message
        Snippet = $snippet
    }
}

$files = @(Get-InputFiles -InputPath $Path -Recursive $Recurse | Sort-Object FullName -Unique)
$parsed = [System.Collections.Generic.List[object]]::new()
$knownFunctions = @{}
$definedFunctions = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$functionDefinitions = [System.Collections.Generic.List[object]]::new()

foreach ($file in $files) {
    $tokens = $null
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile(
        $file.FullName, [ref]$tokens, [ref]$parseErrors)
    if (@($parseErrors).Count -gt 0) {
        $details = ($parseErrors | ForEach-Object {
                "$($_.Extent.StartLineNumber):$($_.Extent.StartColumnNumber) $($_.Message)"
            }) -join '; '
        throw "Cannot analyze '$($file.FullName)': $details"
    }
    [void]$parsed.Add([pscustomobject]@{ File = $file.FullName; Ast = $ast })

    foreach ($function in $ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst]
            }, $true)) {
        [void]$definedFunctions.Add([string]$function.Name)
        $protection = Get-CollectionReturnProtection -Function $function
        [void]$functionDefinitions.Add([pscustomobject]@{
                File         = $file.FullName
                Name         = [string]$function.Name
                AnyProtected = [bool]$protection.Any
                AllProtected = [bool]$protection.All
            })
        $parameters = @()
        if ($null -ne $function.Body.ParamBlock) {
            $parameters = @($function.Body.ParamBlock.Parameters)
        }
        $arrayParameters = @{}
        for ($index = 0; $index -lt $parameters.Count; $index++) {
            $parameter = $parameters[$index]
            if ($parameter.StaticType.IsArray -and (Test-MandatoryAttribute -Parameter $parameter)) {
                $arrayParameters[[string]$parameter.Name.VariablePath.UserPath] = $index
            }
        }
        if ($arrayParameters.Count -gt 0) {
            $knownFunctions[$function.Name] = $arrayParameters
        }
    }
}

$findings = [System.Collections.Generic.List[object]]::new()

# The protected-return exemption is resolved per file, never repo-wide by bare
# name: a protected Get-Foo in one file must not exempt call sites of a
# different, unprotected Get-Foo in another. A definition from elsewhere is
# honoured only when the name is defined exactly once across the scan.
$definitionsByName = @{}
foreach ($definition in $functionDefinitions) {
    $key = $definition.Name.ToLowerInvariant()
    if (-not $definitionsByName.ContainsKey($key)) {
        $definitionsByName[$key] = [System.Collections.Generic.List[object]]::new()
    }
    [void]$definitionsByName[$key].Add($definition)
}
$exemptByFile = @{}
$nestingByFile = @{}
foreach ($document in $parsed) {
    $exempt = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $nesting = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($key in $definitionsByName.Keys) {
        $allDefinitions = @($definitionsByName[$key])
        $localDefinitions = @($allDefinitions | Where-Object { $_.File -eq $document.File })
        $visible = $localDefinitions
        if ($localDefinitions.Count -eq 0) {
            if ($allDefinitions.Count -ne 1) { continue }
            $visible = $allDefinitions
        }
        $name = $visible[0].Name
        if (@($visible | Where-Object { -not $_.AllProtected }).Count -eq 0) { [void]$exempt.Add($name) }
        if (@($visible | Where-Object { $_.AnyProtected }).Count -gt 0) { [void]$nesting.Add($name) }
    }
    $exemptByFile[$document.File] = $exempt
    $nestingByFile[$document.File] = $nesting
}

foreach ($document in $parsed) {
    $ast = $document.Ast
    $file = $document.File
    # Assignment rules only stand down when every exit is protected; the
    # wrapping rule fires whenever any exit is, because that path nests.
    $protectedReturnFunctions = $exemptByFile[$file]
    $nestingReturnFunctions = $nestingByFile[$file]

    foreach ($assignment in $ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.AssignmentStatementAst]
            }, $true)) {
        if ((Test-ArrayTypeConstraint -Ast $assignment.Left) -and
            (Test-ContainsCommandOutput -Ast $assignment.Right) -and
            -not (Test-ExplicitArrayPreservation -Ast $assignment.Right)) {
            [void]$findings.Add((New-Finding -RuleId 'PSEN001' -File $file -Ast $assignment `
                        -Message 'Preserve command output explicitly before assigning it to a typed array.'))
        }
    }

    foreach ($command in $ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.CommandAst]
            }, $true)) {
        $name = $command.GetCommandName()
        if ([string]::IsNullOrWhiteSpace($name) -or -not $knownFunctions.ContainsKey($name)) { continue }
        $mandatoryArrays = $knownFunctions[$name]
        $elements = @($command.CommandElements)
        $positionalIndex = 0
        for ($index = 1; $index -lt $elements.Count; $index++) {
            $element = $elements[$index]
            $parameterName = $null
            $argument = $null
            if ($element -is [Management.Automation.Language.CommandParameterAst]) {
                $parameterName = [string]$element.ParameterName
                if ($index + 1 -lt $elements.Count -and
                    $elements[$index + 1] -isnot [Management.Automation.Language.CommandParameterAst]) {
                    $argument = $elements[++$index]
                }
            }
            else {
                $argument = $element
                $parameterName = @($mandatoryArrays.GetEnumerator() |
                        Where-Object Value -eq $positionalIndex |
                        Select-Object -First 1).Key
                $positionalIndex++
            }
            if ([string]::IsNullOrWhiteSpace($parameterName) -or
                -not $mandatoryArrays.ContainsKey($parameterName) -or $null -eq $argument) {
                continue
            }
            if ((Test-ContainsCommandOutput -Ast $argument) -and
                -not (Test-ExplicitArrayPreservation -Ast $argument)) {
                [void]$findings.Add((New-Finding -RuleId 'PSEN001' -File $file -Ast $argument `
                            -Message "Preserve command output explicitly for mandatory array parameter '$parameterName'."))
            }
        }
    }

    foreach ($array in $ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.ArrayExpressionAst]
            }, $true)) {
        $hasExplicitNull = @($array.FindAll({
                    param($node)
                    $node -is [Management.Automation.Language.VariableExpressionAst] -and
                    $node.VariablePath.UserPath -ieq 'null'
                }, $true)).Count -gt 0
        if ($hasExplicitNull -and -not (Test-NullRemovingFilter -Array $array)) {
            [void]$findings.Add((New-Finding -RuleId 'PSEN002' -File $file -Ast $array `
                        -Message 'This array expression can preserve an explicit null as a phantom element.'))
        }
    }

    foreach ($member in $ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.MemberExpressionAst] -and
                $node.Member -is [Management.Automation.Language.StringConstantExpressionAst] -and
                [string]$node.Member.Value -ieq 'Sum'
            }, $true)) {
        $measure = @($member.Expression.FindAll({
                    param($node)
                    $node -is [Management.Automation.Language.CommandAst] -and
                    $node.GetCommandName() -in 'Measure-Object', 'measure' -and
                    @($node.CommandElements | Where-Object {
                            $_ -is [Management.Automation.Language.CommandParameterAst] -and
                            $_.ParameterName -ieq 'Sum'
                        }).Count -gt 0
                }, $true))
        if ($measure.Count -eq 0) { continue }
        $inputVariable = Get-MeasureInputVariable -Member $member
        if (-not (Test-MeasureDefaulted -Member $member) -and
            -not (Test-MeasureGuarded -Member $member -Variable $inputVariable)) {
            [void]$findings.Add((New-Finding -RuleId 'PSEN003' -File $file -Ast $member `
                        -Message 'Default .Sum or prove the Measure-Object -Sum input is non-empty before access.'))
        }
    }

    # PSEN004: a function that constructs a .NET collection locally and then
    # returns the variable bare. The return enumerates it, so zero elements
    # arrive at the caller as $null and one element arrives as a scalar.
    foreach ($function in $ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst]
            }, $true)) {
        $collectionNames = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)
        foreach ($assignment in $function.Body.FindAll({
                    param($node)
                    $node -is [Management.Automation.Language.AssignmentStatementAst]
                }, $true)) {
            $left = $assignment.Left
            if ($left -is [Management.Automation.Language.ConvertExpressionAst]) { $left = $left.Child }
            if ($left -isnot [Management.Automation.Language.VariableExpressionAst]) { continue }
            if (Test-EnumeratingCollectionConstruction -Ast $assignment.Right) {
                [void]$collectionNames.Add((Get-VariableName -VariablePath $left.VariablePath))
            }
        }
        if ($collectionNames.Count -eq 0) { continue }

        $returns = @($function.Body.FindAll({
                    param($node)
                    $node -is [Management.Automation.Language.ReturnStatementAst]
                }, $true))
        foreach ($return in $returns) {
            if ($null -eq $return.Pipeline) { continue }
            $name = Get-BareVariableName -Ast $return.Pipeline
            if ($null -ne $name -and $collectionNames.Contains($name)) {
                [void]$findings.Add((New-Finding -RuleId 'PSEN004' -File $file -Ast $return `
                            -Message "Return the '$name' collection without enumerating it (Write-Output -NoEnumerate or a leading comma); a bare return turns an empty collection into `$null."))
            }
        }
        foreach ($namedBlock in @($function.Body.BeginBlock, $function.Body.ProcessBlock, $function.Body.EndBlock)) {
            if ($null -eq $namedBlock) { continue }
            $statements = @($namedBlock.Statements)
            if ($statements.Count -eq 0) { continue }
            $last = $statements[$statements.Count - 1]
            if ($last -is [Management.Automation.Language.ReturnStatementAst]) { continue }
            $name = Get-BareVariableName -Ast $last
            if ($null -ne $name -and $collectionNames.Contains($name)) {
                [void]$findings.Add((New-Finding -RuleId 'PSEN004' -File $file -Ast $last `
                            -Message "Emit the '$name' collection without enumerating it (Write-Output -NoEnumerate or a leading comma); a bare trailing expression turns an empty collection into `$null."))
            }
        }
    }

    # PSEN005: counting or indexing straight into an unconstrained command or
    # pipeline expression, whose cardinality is not statically known.
    foreach ($member in $ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.MemberExpressionAst] -and
                $node -isnot [Management.Automation.Language.InvokeMemberExpressionAst] -and
                $node.Member -is [Management.Automation.Language.StringConstantExpressionAst] -and
                [string]$node.Member.Value -iin @('Count', 'Length')
            }, $true)) {
        if ($null -ne (Get-UnconstrainedCommandSource -Ast $member.Expression -ProtectedNames $protectedReturnFunctions)) {
            [void]$findings.Add((New-Finding -RuleId 'PSEN005' -File $file -Ast $member `
                        -Message "Wrap the command result in @(...) before reading .$($member.Member.Value); an unconstrained pipeline can yield `$null or a scalar."))
        }
    }
    foreach ($index in $ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.IndexExpressionAst]
            }, $true)) {
        if ($null -ne (Get-UnconstrainedCommandSource -Ast $index.Target -ProtectedNames $protectedReturnFunctions)) {
            [void]$findings.Add((New-Finding -RuleId 'PSEN005' -File $file -Ast $index `
                        -Message 'Wrap the command result in @(...) before indexing it; an unconstrained pipeline can yield $null or a scalar.'))
        }
    }

    # PSEN006: a script block that reads a name this file also assigns at script
    # scope, without qualifying it. Whether the block sees the value captured at
    # definition time or the ambient value at invocation time then depends on
    # GetNewClosure and on the runspace state, not on the code.
    $scriptScoped = Get-ScriptScopedNames -Ast $ast
    if ($scriptScoped.Count -gt 0) {
        foreach ($block in $ast.FindAll({
                    param($node)
                    $node -is [Management.Automation.Language.ScriptBlockExpressionAst]
                }, $true)) {
            $local = Get-ScriptBlockLocalNames -ScriptBlock $block.ScriptBlock
            foreach ($variable in $block.FindAll({
                        param($node)
                        $node -is [Management.Automation.Language.VariableExpressionAst]
                    }, $true)) {
                $variablePath = $variable.VariablePath
                if ($variablePath.IsScript -or $variablePath.IsGlobal -or $variablePath.IsPrivate -or
                    -not [string]::IsNullOrEmpty($variablePath.DriveName)) {
                    continue
                }
                $name = (Get-VariableName -VariablePath $variablePath)
                if ($name -iin @('_', 'null', 'true', 'false', 'PSItem', 'args', 'this', 'input')) { continue }
                if ($local.Contains($name) -or -not $scriptScoped.Contains($name)) { continue }
                [void]$findings.Add((New-Finding -RuleId 'PSEN006' -File $file -Ast $variable `
                            -Message "Capture '`$$name' explicitly (a parameter, an argument, or `$script:$name); this script block reads a script-scoped name unqualified."))
            }
        }
    }

    foreach ($command in $ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.CommandAst] -and
                $node.GetCommandName() -in 'ConvertTo-Json', 'convertto-json'
            }, $true)) {
        # PSEN007: without an explicit -Depth the serialized shape of a contract
        # is whatever the host defaults to, and nested collections truncate.
        if (-not (Test-CommandParameterPresent -Command $command -NamePrefix 'Dep')) {
            [void]$findings.Add((New-Finding -RuleId 'PSEN007' -File $file -Ast $command `
                        -Message 'Pass an explicit -Depth to ConvertTo-Json; the default depth silently truncates nested contract collections.'))
        }
        # PSEN008: a contract that reaches a file must state its on-disk form.
        if (-not (Test-CommandParameterPresent -Command $command -NamePrefix 'Com') -and
            (Test-ContractWriteContext -Ast $command)) {
            [void]$findings.Add((New-Finding -RuleId 'PSEN008' -File $file -Ast $command `
                        -Message 'State -Compress (or -Compress:$false) explicitly for a ConvertTo-Json result that is written to a file.'))
        }
    }

    # PSEN011: @(...) around a call to a function that deliberately protects its
    # collection return does not flatten that return, it nests it as a single
    # element. This is how an index built from a protected array collapsed to one
    # bogus entry while every count still looked plausible.
    foreach ($wrap in $ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.ArrayExpressionAst]
            }, $true)) {
        $statements = @($wrap.SubExpression.Statements)
        if ($statements.Count -ne 1) { continue }
        $inner = $statements[0]
        if ($inner -isnot [Management.Automation.Language.PipelineAst]) { continue }
        $elements = @($inner.PipelineElements)
        if ($elements.Count -ne 1) { continue }
        $command = $elements[0]
        if ($command -isnot [Management.Automation.Language.CommandAst]) { continue }
        $wrappedName = $command.GetCommandName()
        if ([string]::IsNullOrWhiteSpace($wrappedName) -or
            -not $nestingReturnFunctions.Contains($wrappedName)) {
            continue
        }
        [void]$findings.Add((New-Finding -RuleId 'PSEN011' -File $file -Ast $wrap `
                    -Message "Assign '$wrappedName' to a variable and wrap the variable; @($wrappedName ...) nests the protected collection as one element instead of flattening it."))
    }

    # PSEN010: GetNewClosure captures variables, not function definitions. A
    # closure that calls a repository function by name resolves that name in
    # whatever scope later invokes it, which is how a closure that worked in the
    # defining scope failed once it ran under a different reader.
    foreach ($closure in $ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
                $node.Member -is [Management.Automation.Language.StringConstantExpressionAst] -and
                [string]$node.Member.Value -ieq 'GetNewClosure' -and
                $node.Expression -is [Management.Automation.Language.ScriptBlockExpressionAst]
            }, $true)) {
        $reported = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)
        foreach ($call in $closure.Expression.FindAll({
                    param($node)
                    $node -is [Management.Automation.Language.CommandAst]
                }, $true)) {
            $callName = $call.GetCommandName()
            if ([string]::IsNullOrWhiteSpace($callName) -or
                -not $definedFunctions.Contains($callName) -or
                -not $reported.Add($callName)) {
                continue
            }
            [void]$findings.Add((New-Finding -RuleId 'PSEN010' -File $file -Ast $call `
                        -Message "Capture '$callName' explicitly (for example `${function:$callName}) and invoke it through the captured reference; GetNewClosure captures variables, not function definitions."))
        }
    }

    # PSEN009: a non-preserved command result is assigned, then counted or
    # indexed later in the same scope, so a single result flattens to a scalar
    # and an empty result becomes $null. One cardinality-use index is built per
    # file so this stays linear in AST size.
    $cardinalityUses = @{}
    foreach ($use in $ast.FindAll({
                param($node)
                if ($node -is [Management.Automation.Language.MemberExpressionAst] -and
                    $node -isnot [Management.Automation.Language.InvokeMemberExpressionAst] -and
                    $node.Member -is [Management.Automation.Language.StringConstantExpressionAst] -and
                    [string]$node.Member.Value -iin @('Count', 'Length')) {
                    return $node.Expression -is [Management.Automation.Language.VariableExpressionAst]
                }
                return ($node -is [Management.Automation.Language.IndexExpressionAst] -and
                    $node.Target -is [Management.Automation.Language.VariableExpressionAst])
            }, $true)) {
        $target = if ($use -is [Management.Automation.Language.IndexExpressionAst]) { $use.Target } else { $use.Expression }
        $useName = (Get-VariableName -VariablePath $target.VariablePath).ToLowerInvariant()
        if (-not $cardinalityUses.ContainsKey($useName)) {
            $cardinalityUses[$useName] = [System.Collections.Generic.List[object]]::new()
        }
        [void]$cardinalityUses[$useName].Add($use)
    }

    foreach ($assignment in $ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.AssignmentStatementAst] -and
                $node.Operator -eq [Management.Automation.Language.TokenKind]::Equals -and
                $node.Left -is [Management.Automation.Language.VariableExpressionAst]
            }, $true)) {
        $variablePath = $assignment.Left.VariablePath
        if (-not $variablePath.IsUnqualified) { continue }
        $displayName = (Get-VariableName -VariablePath $variablePath)
        $name = $displayName.ToLowerInvariant()
        if (-not $cardinalityUses.ContainsKey($name)) { continue }
        if (-not (Test-ContainsCommandOutput -Ast $assignment.Right) -or
            (Test-UnwrappedArrayPreservation -Ast $assignment.Right)) {
            continue
        }
        # A call to a function that protects its own collection return already
        # hands the caller the collection itself; wrapping it here would nest it.
        if (Test-ProtectedReturnSource -Ast $assignment.Right -ProtectedNames $protectedReturnFunctions) {
            continue
        }
        $scope = $assignment.Parent
        while ($null -ne $scope -and
            $scope -isnot [Management.Automation.Language.FunctionDefinitionAst] -and
            $scope -isnot [Management.Automation.Language.ScriptBlockAst]) {
            $scope = $scope.Parent
        }
        if ($null -eq $scope) { continue }
        $matched = $false
        foreach ($use in $cardinalityUses[$name]) {
            if ($use.Extent.StartOffset -ge $assignment.Extent.EndOffset -and
                $use.Extent.StartOffset -ge $scope.Extent.StartOffset -and
                $use.Extent.EndOffset -le $scope.Extent.EndOffset) {
                $matched = $true
                break
            }
        }
        if ($matched) {
            [void]$findings.Add((New-Finding -RuleId 'PSEN009' -File $file -Ast $assignment `
                        -Message "Preserve '`$$displayName' with @(...) at assignment; it is later counted or indexed, and a single command result flattens to a scalar."))
        }
    }
}

$deduped = [System.Collections.Generic.List[object]]::new()
$seen = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::Ordinal)
foreach ($finding in $findings) {
    if ($seen.Add("$($finding.RuleId)|$($finding.File)|$($finding.Line)|$($finding.Column)")) {
        [void]$deduped.Add($finding)
    }
}
$selected = $deduped
if ($PSBoundParameters.ContainsKey('RuleId')) {
    $selected = @($deduped | Where-Object { $RuleId -contains $_.RuleId })
}
$ordered = @($selected | Sort-Object File, Line, Column, RuleId)
if ($OutputFormat -eq 'Json') {
    ConvertTo-Json -InputObject $ordered -Depth 4 -Compress
}
else {
    $ordered
}
