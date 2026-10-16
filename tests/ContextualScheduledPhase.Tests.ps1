#requires -Version 7.0

BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $producer = Join-Path $repoRoot `
        'tools\Invoke-ContextualDeliveryBatchJson.ps1'
    $phase = Join-Path $repoRoot `
        'tools\Invoke-ContextualConventionsScheduledPhase.ps1'
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile(
        $phase, [ref]$tokens, [ref]$errors)
    $errors | Should -HaveCount 0
    $function = @($ast.FindAll({
                param($node)
                $node -is [
                    Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -ceq
                    'Get-ContextualScheduledObservationDisposition'
            }, $true))[0]
    Invoke-Expression $function.Extent.Text
}

Describe 'Contextual scheduled observation disposition' {
    BeforeEach {
        $observation = [ordered]@{
            lifecycle = [ordered]@{
                status = 'completed'
            }
            findingsComplete = $true
            counts = [ordered]@{
                unknown = 0
            }
            effects = [ordered]@{
                providerWrites = 0
                dedupe = [ordered]@{
                    unknown = 0
                }
            }
            execution = [ordered]@{
                modelStarts = 0
            }
            validationErrors = @()
            findings = @([ordered]@{
                    ruleId = 'explicit-string-comparison'
                })
        }
    }

    It 'keeps a complete observation deliverable' {
        $result =
            Get-ContextualScheduledObservationDisposition `
                -Observation $observation `
                -AllowedRuleIds @(
                    'explicit-string-comparison')

        $result.deliverable | Should -BeTrue
        $result.reason | Should -BeExactly complete
    }

    It 'withholds an ambiguous discussion without treating it as unsafe' {
        $observation.findingsComplete = $false
        $observation.effects.dedupe.unknown = 1

        $result =
            Get-ContextualScheduledObservationDisposition `
                -Observation $observation `
                -AllowedRuleIds @(
                    'explicit-string-comparison')

        $result.deliverable | Should -BeFalse
        $result.reason |
            Should -BeExactly discussion-reconciliation-unknown
        $result.reconciliationUnknown | Should -Be 1
    }

    It 'still rejects observations that report provider writes' {
        $observation.effects.providerWrites = 1

        {
            Get-ContextualScheduledObservationDisposition `
                -Observation $observation `
                -AllowedRuleIds @(
                    'explicit-string-comparison')
        } | Should -Throw contextual-phase-observation-unsafe
    }
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
