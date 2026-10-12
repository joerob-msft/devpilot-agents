#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$AutomaticDeliveryTool,
    [Parameter(Mandatory)][string]$DeliveryRoot,
    [Parameter(Mandatory)][string]$StateRoot,
    [Parameter(Mandatory)]
    [ValidateCount(1, 4)]
    [ValidatePattern('^[0-9a-f]{64}$')]
    [string[]]$Identity,
    [Parameter(Mandatory)]
    [string]$ToolkitConfigPath,
    [Parameter(Mandatory)][string]$AzureCliPath,
    [Parameter(Mandatory)][string]$GitPath,
    [Parameter(Mandatory)][string]$RepoRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$WarningPreference = 'SilentlyContinue'
[Console]::OutputEncoding =
    [Text.UTF8Encoding]::new($false)

try {
    $result = & $AutomaticDeliveryTool `
        invoke-batch `
        -Delivery contextual-conventions `
        -DeliveryRoot $DeliveryRoot `
        -StateRoot $StateRoot `
        -Identity $Identity `
        -ToolkitConfigPath $ToolkitConfigPath `
        -MaxCreatesPerRun 2 `
        -MaxCreatesPerPullRequest 5 `
        -AzureCliPath $AzureCliPath `
        -GitPath $GitPath `
        -RepoRoot $RepoRoot
    $exitCode = $LASTEXITCODE
    if ($exitCode -notin @(0, 2, 3)) {
        throw 'contextual-delivery-tool-failed'
    }
    [ordered]@{
        schemaVersion = 1
        kind =
            'contextual-conventions-delivery-producer-result'
        toolExitCode = $exitCode
        result = $result
    } | ConvertTo-Json -Depth 64
    exit 0
}
catch {
    [Console]::Error.WriteLine(
        'contextual-delivery-producer-failed')
    exit 1
}
