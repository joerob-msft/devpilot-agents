#requires -Version 7.0

BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $producer = Join-Path $repoRoot `
        'tools\Invoke-ContextualDeliveryBatchJson.ps1'
}

Describe 'Contextual delivery producer' {
    It 'preserves automatic delivery objects and exit health' `
        -TestCases @(
            @{
                ExitCode = 0
                Health = 'healthy'
            },
            @{
                ExitCode = 2
                Health = 'partial'
            },
            @{
                ExitCode = 3
                Health = 'refused'
            }
        ) {
        param($ExitCode, $Health)
        $tool = Join-Path $TestDrive `
            "automatic-$ExitCode.ps1"
        $body = @"
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]`$Command,
    [string]`$Delivery,
    [string]`$DeliveryRoot,
    [string]`$StateRoot,
    [string[]]`$Identity,
    [string]`$ToolkitConfigPath,
    [int]`$MaxCreatesPerRun,
    [int]`$MaxCreatesPerPullRequest,
    [string]`$AzureCliPath,
    [string]`$GitPath,
    [string]`$RepoRoot
)
[pscustomobject][ordered]@{
    schemaVersion = 1
    kind = 'contextual-conventions-v1-automatic-delivery-batch-result'
    health = '$Health'
    providerWrites = $(if ($ExitCode -eq 0) { 1 } else { 0 })
    modelWrites = 0
    remainingCreates = 1
    remainingWouldCreate = 0
    results = @()
    deferred = @()
    events = @()
}
exit $ExitCode
"@
        [IO.File]::WriteAllText(
            $tool,
            $body,
            [Text.UTF8Encoding]::new($false))
        $output = @(
            & $producer `
                -AutomaticDeliveryTool $tool `
                -DeliveryRoot $TestDrive `
                -StateRoot $TestDrive `
                -Identity ('a' * 64) `
                -ToolkitConfigPath $tool `
                -AzureCliPath $tool `
                -GitPath $tool `
                -RepoRoot $TestDrive)
        $LASTEXITCODE | Should -Be 0 `
            -Because ($output -join "`n")
        $envelope = ($output -join "`n") |
            ConvertFrom-Json -AsHashtable `
                -Depth 32
        $envelope.toolExitCode |
            Should -Be $ExitCode
        $envelope.result.health |
            Should -BeExactly $Health
        $envelope.result.modelWrites |
            Should -Be 0
    }
}
