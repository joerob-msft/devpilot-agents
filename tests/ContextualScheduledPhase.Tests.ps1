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

    function New-ContextualScheduledEntryCase {
        param(
            [ValidateSet('complete', 'missing-rule', 'duplicate-rule', 'missing-id', 'malformed-json')]
            [string]$Mode = 'complete'
        )
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $toolkit = Join-Path $root 'toolkit'
        [void][IO.Directory]::CreateDirectory($root)
        $git = (Get-Command git -CommandType Application | Select-Object -First 1).Source
        & $git clone --shared --no-checkout --quiet $repoRoot $toolkit
        if ($LASTEXITCODE -ne 0) { throw 'Scheduled entrypoint fixture clone failed.' }
        $sourceHead = (& $git -C $repoRoot rev-parse HEAD).Trim()
        & $git -C $toolkit checkout --detach --quiet $sourceHead
        if ($LASTEXITCODE -ne 0) { throw 'Scheduled entrypoint fixture checkout failed.' }
        $phasePath = Join-Path $toolkit 'tools\Invoke-ContextualConventionsScheduledPhase.ps1'
        [IO.File]::WriteAllBytes($phasePath, [IO.File]::ReadAllBytes($phase))
        $policyPath = Join-Path $toolkit 'src\DevPilot.OwnerCapability\Policy\contextual-conventions.v1.json'
        [IO.File]::WriteAllBytes($policyPath, [IO.File]::ReadAllBytes(
            (Join-Path $repoRoot 'src\DevPilot.OwnerCapability\Policy\contextual-conventions.v1.json')))
        $policy = Get-Content -LiteralPath $policyPath -Raw | ConvertFrom-Json -AsHashtable
        @($policy.rules) | Should -HaveCount 27
        switch ($Mode) {
            missing-rule { $policy.rules = @($policy.rules | Select-Object -SkipLast 1) }
            duplicate-rule { $policy.rules[-1] = $policy.rules[0] }
            missing-id { [void]$policy.rules[-1].Remove('id') }
        }
        if ($Mode -ceq 'malformed-json') {
            [IO.File]::WriteAllText($policyPath, '{"rules":[')
        }
        elseif ($Mode -cne 'complete') {
            [IO.File]::WriteAllText($policyPath, ($policy | ConvertTo-Json -Depth 32))
        }
        $changes = @(& $git -C $toolkit status --porcelain)
        if ($changes.Count -gt 0) {
            $hooks = Join-Path $root 'empty-hooks'
            [void][IO.Directory]::CreateDirectory($hooks)
            & $git -C $toolkit add -- tools\Invoke-ContextualConventionsScheduledPhase.ps1 `
                src\DevPilot.OwnerCapability\Policy\contextual-conventions.v1.json
            if ($LASTEXITCODE -ne 0) { throw 'Scheduled entrypoint fixture staging failed.' }
            & $git -C $toolkit -c user.name=DevPilotFixture -c user.email=fixture@example.invalid `
                -c commit.gpgsign=false -c "core.hooksPath=$hooks" commit --quiet `
                -m 'Pin isolated scheduled entrypoint test inputs'
            if ($LASTEXITCODE -ne 0) { throw 'Scheduled entrypoint fixture commit failed.' }
        }
        $head = (& $git -C $toolkit rev-parse HEAD).Trim()
        $tree = (& $git -C $toolkit rev-parse 'HEAD^{tree}').Trim()
        @(& $git -C $toolkit status --porcelain) | Should -HaveCount 0
        (Get-FileHash -LiteralPath $phasePath).Hash | Should -BeExactly (
            Get-FileHash -LiteralPath $phase).Hash
        $config = Join-Path $root 'evaluation.config.json'
        Copy-Item -LiteralPath (Join-Path $toolkit 'samples\contextual-conventions-current-pr.config.json') `
            -Destination $config
        Copy-Item -LiteralPath $config -Destination (
            Join-Path $root 'contextual-conventions-delivery.config.json')
        $acquisition = Join-Path $root 'shared-acquisition.json'
        [IO.File]::WriteAllText($acquisition, (@{
            schemaVersion = 1
            kind = 'devpilot-shared-review-acquisition'
            generation = 'scheduled-entry-disabled-fixture'
            configDigest = 'a' * 64
            intake = @{
                generation = 'scheduled-entry-disabled-fixture'
                binding = @{configDigest = 'a' * 64}
            }
        } | ConvertTo-Json -Depth 8))
        $cli = Join-Path $root 'must-not-invoke-cli.ps1'
        [IO.File]::WriteAllText($cli, @'
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'unexpected-provider-call.txt'), 'unexpected')
throw 'Disabled scheduled entrypoint invoked a provider.'
'@)
        $deliveryRoot = Join-Path $root 'delivery'
        $laneRoot = Join-Path $deliveryRoot 'contextual-conventions-v1'
        $keys = Join-Path $laneRoot 'keys'
        [void][IO.Directory]::CreateDirectory($keys)
        [void][IO.Directory]::CreateDirectory((Join-Path $laneRoot 'events'))
        [IO.File]::WriteAllBytes(
            (Join-Path $keys 'contextual-conventions-service-authorization.hmac'),
            [byte[]](1..32))
        return @{
            Root = $root
            PhasePath = $phasePath
            Arguments = @{
                ContextualToolkitRoot = $toolkit
                ContextualConfigPath = $config
                ContextualStateRoot = Join-Path $root 'state'
                ContextualManifestPath = Join-Path $root 'manifest.json'
                AutomaticDeliveryRoot = $deliveryRoot
                SharedAcquisitionPath = $acquisition
                SharedAcquisitionSha256 = (Get-FileHash -LiteralPath $acquisition).Hash.ToLowerInvariant()
                AzureCliPath = $cli
                GitPath = $git
                ExpectedToolkitHead = $head
                ExpectedToolkitTree = $tree
            }
        }
    }
}

Describe 'Contextual scheduled source entrypoint' {
    It 'accepts all 27 policy rules and reaches the actual disabled evaluation without provider or delivery writes' {
        $case = New-ContextualScheduledEntryCase
        $arguments = $case.Arguments
        $output = @(& (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source -NoProfile -NonInteractive `
            -File $case.PhasePath @arguments 2>&1)
        $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")
        $result = ($output -join "`n") | ConvertFrom-Json -AsHashtable -Depth 64
        $result.kind | Should -BeExactly contextual-conventions-scheduled-phase-result
        $result.toolkit.head | Should -BeExactly $arguments.ExpectedToolkitHead
        $result.toolkit.tree | Should -BeExactly $arguments.ExpectedToolkitTree
        $result.evaluation.state | Should -BeExactly disabled
        @($result.evaluation.records) | Should -HaveCount 0
        $result.withheldHeadCount | Should -Be 0
        $result.coverage.selectedHeadCount | Should -Be 0
        $result.coverage.withheldHeadCount | Should -Be 0
        $result.deliveryEnabled | Should -BeFalse
        $result.delivery.health | Should -BeExactly disabled
        $result.delivery.remainingCreates | Should -Be 2
        @($result.delivery.events) | Should -HaveCount 0
        $result.evaluationEffects.providerWrites | Should -Be 0
        $result.evaluationEffects.modelWrites | Should -Be 0
        $result.deliveryEffects.providerWrites | Should -Be 0
        $result.deliveryEffects.modelWrites | Should -Be 0
        Test-Path (Join-Path $case.Root 'unexpected-provider-call.txt') | Should -BeFalse
        Test-Path $arguments.ContextualManifestPath | Should -BeFalse
        $history = Get-Content -LiteralPath (
            Join-Path $arguments.ContextualStateRoot 'authenticated-history\contextual-prior-comments.json') `
            -Raw | ConvertFrom-Json -AsHashtable
        @($history.comments) | Should -HaveCount 0
        @(Get-ChildItem -LiteralPath $arguments.AutomaticDeliveryRoot -Recurse -File) |
            Should -HaveCount 1
    }

    It 'fails closed before evaluation for a <Mode> policy allowset' -TestCases @(
        @{Mode='missing-rule'; Error='contextual-phase-rule-allowset-invalid'},
        @{Mode='duplicate-rule'; Error='contextual-phase-rule-allowset-invalid'},
        @{Mode='missing-id'; Error="The property 'id' cannot be found"},
        @{Mode='malformed-json'; Error='Conversion from JSON failed'}
    ) {
        param($Mode, $Error)
        $case = New-ContextualScheduledEntryCase -Mode $Mode
        $arguments = $case.Arguments
        $output = @(& (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source -NoProfile -NonInteractive `
            -File $case.PhasePath @arguments 2>&1)
        $LASTEXITCODE | Should -Not -Be 0
        ($output -join "`n") | Should -Match ([regex]::Escape($Error))
        Test-Path $arguments.ContextualStateRoot | Should -BeFalse
        Test-Path $arguments.ContextualManifestPath | Should -BeFalse
        Test-Path (Join-Path $case.Root 'unexpected-provider-call.txt') | Should -BeFalse
        @(Get-ChildItem -LiteralPath $arguments.AutomaticDeliveryRoot -Recurse -File) |
            Should -HaveCount 1
    }
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

    It 'delivers disjoint code findings beside an isolated PR-wide template discussion unknown' {
        $observation.findingsComplete = $false
        $observation.effects.dedupe.unknown = 1
        $observation.findings = @(
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
                    classification = 'unknown'
                    reason =
                        'duplicate-or-foreign-reviewer-marker'
                }
            },
            [ordered]@{
                anchor = [ordered]@{
                    path = 'src/Test.cs'
                    line = 20
                }
                constructRef =
                    'construct:code-actionable'
                ruleId =
                    'explicit-string-comparison'
                reconciliation = [ordered]@{
                    classification = 'wouldCreate'
                    reason =
                        'no-current-review-at-anchor'
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
        $result.reconciliationUnknown | Should -Be 1
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
