#requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$providerPath = Join-Path $PSScriptRoot '..\src\Agents\reviewer\AzureDevOpsOwnerV2CommentProvider.ps1'
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($providerPath, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Owner provider does not parse.' }
$assignment = $ast.Find({
    param($node)
    $node -is [Management.Automation.Language.AssignmentStatementAst] -and
    $node.Left -is [Management.Automation.Language.VariableExpressionAst] -and
    $node.Left.VariablePath.UserPath -ceq 'getChangedSpans'
}, $true)
if ($null -eq $assignment) { throw 'Owner getChangedSpans closure was not found.' }
$expression = $assignment.Right.Find({
    param($node)
    $node -is [Management.Automation.Language.ScriptBlockExpressionAst]
}, $true)
if ($null -eq $expression) { throw 'Owner getChangedSpans script block was not found.' }
$getItemContent = {
    param([string]$Path, [string]$Commit)
    switch ($Commit) {
        'source' { return "changed-1`nsame-2`nsame-3`nsame-4`nchanged-5`nsame-6`n" }
        'target' { return "before-1`nsame-2`nsame-3`nsame-4`nbefore-5`nsame-6`n" }
        default { throw "Unexpected commit '$Commit'." }
    }
}.GetNewClosure()
$GitPath = 'C:\Program Files\Git\cmd\git.exe'
$getChangedSpans = $expression.ScriptBlock.GetScriptBlock().GetNewClosure()
$spans = @(& $getChangedSpans -Path 'sample.cs' -ChangeType 'edit' -SourceCommit 'source' -TargetCommit 'target')
if ($spans.Count -ne 2) { throw "Expected two Owner spans; got $($spans.Count)." }
if ([int]$spans[0].startLine -ne 1 -or [int]$spans[0].endLine -ne 1 -or
    [int]$spans[1].startLine -ne 5 -or [int]$spans[1].endLine -ne 5) {
    throw "Owner count-less hunks widened: $($spans | ConvertTo-Json -Compress)."
}
foreach ($neighbor in @(2, 6)) {
    if (@($spans | Where-Object { $neighbor -ge [int]$_.startLine -and $neighbor -le [int]$_.endLine }).Count -ne 0) {
        throw "Unchanged neighboring line $neighbor was accepted."
    }
}$added = @(& $getChangedSpans -Path 'sample.cs' -ChangeType 'add' -SourceCommit 'source' -TargetCommit 'target')
if ($added.Count -ne 1 -or [int]$added[0].startLine -ne 1 -or [int]$added[0].endLine -ne 7) {
    throw "Owner added-file span was not a scalar exact record: $($added | ConvertTo-Json -Compress)."
}
$deleted = @(& $getChangedSpans -Path 'sample.cs' -ChangeType 'delete' -SourceCommit 'source' -TargetCommit 'target')
if ($deleted.Count -ne 0) { throw 'Owner deleted-file span must be empty.' }
[ordered]@{ passed = $true; spans = $spans; providerSha256 = (Get-FileHash -LiteralPath $providerPath -Algorithm SHA256).Hash.ToLowerInvariant() } | ConvertTo-Json -Depth 8