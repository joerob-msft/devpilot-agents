#requires -Version 7.0

BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $repoRoot `
        'src\Agents\reviewer\ApprovedOwnerV2Comments.ps1')
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
    It 'authenticates prior history before ordinary evaluation and passes its digest' {
        $text = Get-Content -LiteralPath $phase -Raw
        $historyIndex = $text.IndexOf(
            'Get-ApprovedOwnerV2AuthenticatedPriorComments',
            [StringComparison]::Ordinal)
        $policyIndex = $text.IndexOf(
            'Read-ApprovedOwnerV2SignedRecord',
            [StringComparison]::Ordinal)
        $harnessIndex = $text.IndexOf(
            'Import-Module $agentHarnessModule',
            [StringComparison]::Ordinal)
        $evaluationIndex = $text.IndexOf(
            '& $currentPrTool',
            [StringComparison]::Ordinal)

        $harnessIndex | Should -BeGreaterThan -1
        $policyIndex | Should -BeGreaterThan -1
        $historyIndex | Should -BeGreaterThan -1
        $policyIndex |
            Should -BeGreaterThan $harnessIndex
        $historyIndex |
            Should -BeGreaterThan $policyIndex
        $evaluationIndex |
            Should -BeGreaterThan $historyIndex
        $text | Should -Match (
            '-AuthenticatedHistoryPath\s+\$historyPath')
        $text | Should -Match (
            '-AuthenticatedHistorySha256\s+`?\s*\$historySha256')
        $text | Should -Match (
            '-RuleCompatibility\s+\$ruleCompatibility')
    }

    It 'wires authenticated history through evaluation and live preflight' {
        $currentTool = Get-Content -LiteralPath (
            Join-Path $repoRoot `
                'tools\Invoke-ContextualConventionsCurrentPr.ps1') -Raw
        $bridge = Get-Content -LiteralPath (
            Join-Path $repoRoot `
                'src\DevPilot.ContextualConventionsBridge\DevPilot.ContextualConventionsBridge.psm1') -Raw
        $orchestrator = Get-Content -LiteralPath (
            Join-Path $repoRoot `
                'src\DevPilot.OwnerOrchestrator\DevPilot.OwnerOrchestrator.psm1') -Raw
        $approved = Get-Content -LiteralPath (
            Join-Path $repoRoot `
                'src\Agents\reviewer\ApprovedOwnerV2Comments.ps1') -Raw
        $automatic = Get-Content -LiteralPath (
            Join-Path $repoRoot `
                'src\Agents\reviewer\AutomaticOwnerV2Comments.ps1') -Raw

        $currentTool | Should -Match (
            '-AuthenticatedPriorComments\s+`?\s*\$authenticatedPriorComments')
        $bridge | Should -Match (
            'Invoke-OwnerV2PreviewRun[\s\S]{0,400}' +
            '-AuthenticatedPriorComments')
        $orchestrator | Should -Match (
            'Invoke-ContextualConventionsLive[\s\S]{0,400}' +
            '-AuthenticatedPriorComments')
        $approved | Should -Match (
            '\[object\[\]\]\$AuthenticatedPriorComments')
        $approved | Should -Match (
            'Resolve-OwnerV2DiscussionReconciliation[\s\S]{0,500}' +
            '-AuthenticatedPriorComments')
        $automatic | Should -Match (
            'Assert-ApprovedOwnerV2LiveRead[\s\S]{0,500}' +
            '-AuthenticatedPriorComments')
    }

    BeforeEach {
        $observation = [ordered]@{
            lifecycle = [ordered]@{
                status = 'completed'
            }
            findingsComplete = $true
            counts = [ordered]@{
                unknown = 0
                uncovered = 0
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
        $observation.findings = @([ordered]@{
                anchor = [ordered]@{
                    path = 'src/Test.cs'
                    line = 10
                }
                constructRef = 'construct:unknown'
                ruleId = 'explicit-string-comparison'
                reconciliation = [ordered]@{
                    classification = 'unknown'
                    reason = 'other-review-at-anchor'
                }
            })

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

    It 'delivers known findings beside disjoint discussion unknowns' {
        $observation.findingsComplete = $false
        $observation.effects.dedupe.unknown = 1
        $observation.findings = @(
            [ordered]@{
                anchor = [ordered]@{
                    path = 'src/Test.cs'
                    line = 10
                }
                constructRef = 'construct:unknown'
                ruleId = 'explicit-string-comparison'
                reconciliation = [ordered]@{
                    classification = 'unknown'
                    reason = 'other-review-at-anchor'
                }
            },
            [ordered]@{
                anchor = [ordered]@{
                    path = 'src/Test.cs'
                    line = 20
                }
                constructRef = 'construct:actionable'
                ruleId = 'http-client-lifetime'
                reconciliation = [ordered]@{
                    classification = 'wouldCreate'
                    reason = 'no-current-review-at-anchor'
                }
            })

        $result =
            Get-ContextualScheduledObservationDisposition `
                -Observation $observation `
                -AllowedRuleIds @(
                    'explicit-string-comparison',
                    'http-client-lifetime')

        $result.deliverable | Should -BeTrue
        $result.reason |
            Should -BeExactly actionable-with-isolated-discussion-unknown
    }

    It 'delivers a PR-wide template finding beside a disjoint code discussion unknown' {
        $observation.findingsComplete = $false
        $observation.effects.dedupe.unknown = 1
        $observation.findings = @(
            [ordered]@{
                anchor = [ordered]@{
                    path = 'src/Test.cs'
                    line = 10
                }
                constructRef =
                    'construct:code-unknown'
                ruleId =
                    'explicit-string-comparison'
                reconciliation = [ordered]@{
                    classification = 'unknown'
                    reason =
                        'other-review-at-anchor'
                }
            },
            [ordered]@{
                anchor = [ordered]@{
                    scope = 'pull-request'
                    subject = 'description'
                }
                constructRef =
                    'construct:pr-template'
                ruleId =
                    'pr-template-compliance'
                issueIdentity =
                    'v1:sha256:' + ('1' * 64)
                reconciliation = [ordered]@{
                    classification =
                        'wouldCreate'
                    reason =
                        'no-current-pr-template-review'
                }
            })

        $result =
            Get-ContextualScheduledObservationDisposition `
                -Observation $observation `
                -AllowedRuleIds @(
                    'explicit-string-comparison',
                    'pr-template-compliance')

        $result.deliverable | Should -BeTrue
        $result.reason |
            Should -BeExactly `
                actionable-with-isolated-discussion-unknown
        $observation.findings[1].anchor.
            Contains('path') |
            Should -BeFalse
        $observation.effects.providerWrites |
            Should -Be 0
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
