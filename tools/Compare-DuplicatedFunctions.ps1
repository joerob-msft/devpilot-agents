#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Compares functions duplicated between an agent and the harness.

.DESCRIPTION
    Deduplication is only safe if the copies actually agree. Two copies of a
    function that drifted apart look identical by name and behave differently,
    and deleting the agent's copy would then silently change behaviour.

    Compares normalized bodies (whitespace and comments removed) via the AST,
    so formatting differences do not register as drift but real ones do.

.EXAMPLE
    ./tools/Compare-DuplicatedFunctions.ps1 -AgentScript ./src/Agents/reviewer-agent/Start-ReviewerAgent.ps1
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$AgentScript,
    [string]$HarnessModule = (Join-Path $PSScriptRoot '..\src\DevPilot.AgentHarness\DevPilot.AgentHarness.psm1')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Get-FunctionBodies {
    param([string]$Path)
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $Path).Path, [ref]$null, [ref]$null)
    $found = $ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
    $map = @{}
    foreach ($fn in $found) {
        # Keep the FIRST definition: later ones inside a self-check are local
        # mocks, not the real implementation.
        if (-not $map.ContainsKey($fn.Name)) { $map[$fn.Name] = $fn }
    }
    return $map
}

function Get-NormalizedBody {
    param($FunctionAst)
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseInput($FunctionAst.Body.Extent.Text, [ref]$tokens, [ref]$errors) | Out-Null
    $meaningful = $tokens | Where-Object {
        $_.Kind -ne [System.Management.Automation.Language.TokenKind]::Comment -and
        $_.Kind -ne [System.Management.Automation.Language.TokenKind]::NewLine -and
        $_.Kind -ne [System.Management.Automation.Language.TokenKind]::EndOfInput
    }
    return (($meaningful | ForEach-Object { $_.Text }) -join ' ')
}

$agent = Get-FunctionBodies -Path $AgentScript
$harness = Get-FunctionBodies -Path $HarnessModule

$shared = @($agent.Keys | Where-Object { $harness.ContainsKey($_) } | Sort-Object)
if ($shared.Count -eq 0) {
    Write-Host "No duplicated function names between the agent and the harness." -ForegroundColor Green
    exit 0
}

Write-Host "Comparing $($shared.Count) function(s) defined in BOTH $(Split-Path $AgentScript -Leaf) and the harness.`n" -ForegroundColor Cyan

$identical = New-Object System.Collections.Generic.List[string]
$drifted = New-Object System.Collections.Generic.List[object]

foreach ($name in $shared) {
    $agentBody = Get-NormalizedBody -FunctionAst $agent[$name]
    $harnessBody = Get-NormalizedBody -FunctionAst $harness[$name]
    if ($agentBody -ceq $harnessBody) {
        [void]$identical.Add($name)
        Write-Host ("  IDENTICAL  {0}" -f $name) -ForegroundColor Green
    }
    else {
        # "Different" is not useful on its own - a reformatted function and a
        # behaviourally changed one both differ. Show the actual token delta so
        # the reader can tell which this is.
        $agentTokens = $agentBody -split ' '
        $harnessTokens = $harnessBody -split ' '
        $delta = Compare-Object $agentTokens $harnessTokens
        $onlyAgent = @($delta | Where-Object SideIndicator -eq '<=' | ForEach-Object { $_.InputObject })
        $onlyHarness = @($delta | Where-Object SideIndicator -eq '=>' | ForEach-Object { $_.InputObject })
        [void]$drifted.Add([pscustomobject]@{
                Name        = $name
                OnlyAgent   = $onlyAgent
                OnlyHarness = $onlyHarness
            })
        Write-Host ("  DRIFTED    {0}" -f $name) -ForegroundColor Yellow
        if ($onlyAgent.Count -gt 0) { Write-Host ("               only in agent  : {0}" -f (($onlyAgent | Select-Object -First 12) -join ' ')) -ForegroundColor DarkYellow }
        if ($onlyHarness.Count -gt 0) { Write-Host ("               only in harness: {0}" -f (($onlyHarness | Select-Object -First 12) -join ' ')) -ForegroundColor DarkYellow }
    }
}

Write-Host ""
Write-Host "$($identical.Count) identical, $($drifted.Count) drifted." -ForegroundColor Cyan
if ($identical.Count -gt 0) {
    Write-Host "`nSafe to delete from the agent and take from the harness:" -ForegroundColor Green
    $identical | ForEach-Object { Write-Host "  $_" }
}
if ($drifted.Count -gt 0) {
    Write-Host "`nNOT safe to delete blindly - reconcile these first:" -ForegroundColor Yellow
    $drifted | ForEach-Object { Write-Host "  $($_.Name)" }
    Write-Host "`nA drifted pair means one copy has a fix the other does not. Deleting the" -ForegroundColor Yellow
    Write-Host "agent's copy would silently adopt the harness's behaviour." -ForegroundColor Yellow
}
exit 0
