#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Finds selected PowerShell empty-output-to-null hazards with the PowerShell AST.

.DESCRIPTION
    Reports three deliberately narrow rule classes:
      PSEN001 - a bare command/pipeline flows into a typed array assignment or a
                mandatory typed-array parameter declared in the analyzed files;
      PSEN002 - an array subexpression contains an explicit $null without a
                recognizable null-removing Where-Object filter; and
      PSEN003 - Measure-Object -Sum is dereferenced through .Sum without a
                recognized default or non-empty input guard.

    This is a heuristic prevention aid, not a PowerShell type or control-flow
    prover. Use -OutputFormat Json for CI or measurement consumers.

.EXAMPLE
    ./tools/Find-PowerShellEmptyNullHazard.ps1 -Path ./src -Recurse -OutputFormat Json
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string[]]$Path,
    [switch]$Recurse,
    [ValidateSet('Object', 'Json')][string]$OutputFormat = 'Object'
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

function New-Finding {
    param(
        [string]$RuleId,
        [string]$Message,
        [string]$File,
        [Management.Automation.Language.Ast]$Ast
    )

    [pscustomobject][ordered]@{
        RuleId = $RuleId
        File = $File
        Line = $Ast.Extent.StartLineNumber
        Column = $Ast.Extent.StartColumnNumber
        Message = $Message
        Snippet = $Ast.Extent.Text
    }
}

$files = @(Get-InputFiles -InputPath $Path -Recursive $Recurse | Sort-Object FullName -Unique)
$parsed = New-Object System.Collections.Generic.List[object]
$knownFunctions = @{}

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

$findings = New-Object System.Collections.Generic.List[object]
foreach ($document in $parsed) {
    $ast = $document.Ast
    $file = $document.File

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
}

$ordered = @($findings | Sort-Object File, Line, Column, RuleId)
if ($OutputFormat -eq 'Json') {
    ConvertTo-Json -InputObject $ordered -Depth 4 -Compress
}
else {
    $ordered
}
