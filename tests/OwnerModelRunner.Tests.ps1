BeforeAll {
    Import-Module "$PSScriptRoot\..\src\DevPilot.OwnerModelRunner\DevPilot.OwnerModelRunner.psd1" -Force
    Import-Module "$PSScriptRoot\..\src\DevPilot.OwnerCapability\DevPilot.OwnerCapability.psd1" -Force

    $script:child = (Resolve-Path "$PSScriptRoot\fixtures\OwnerModelChild.ps1").Path
    $script:pwsh = (Get-Command pwsh).Source

    function New-TestModelRequest {
        param(
            [string]$Name = 'NeedsOwner',
            [string]$Suffix = ('a' * 64)
        )
        return [ordered]@{
            schemaVersion = 2
            semantics = 'owner-mstest-owner-judgment-v2'
            executionUnitId = "unit:$Suffix"
            capability = [ordered]@{
                id = 'owner-example-v2'
                digest = 'v1:sha256:' + ('b' * 64)
            }
            rule = [ordered]@{
                ref = 'rule:' + ('c' * 64)
                content = 'Changed test methods require an Owner attribute.'
            }
            construct = [ordered]@{
                kind = 'method'
                name = $Name
                attributes = @('TestMethod')
                snippet = '[TestMethod] public void Example()'
            }
        }
    }

    function Invoke-TestProcessRunner {
        param(
            [Parameter(Mandatory)][string]$Mode,
            [object]$Request = (New-TestModelRequest),
            [object]$Limits = (New-OwnerModelRunnerLimits),
            [string]$StatePath
        )
        $arguments = @('-NoProfile', '-File', $script:child, $Mode)
        if ($StatePath) { $arguments += $StatePath }
        else { $arguments += '-' }
        $module = Get-Module DevPilot.OwnerModelRunner
        $runner = & $module {
            param($FilePath, $ArgumentList, $Limits)
            New-OwnerModelTestProcessRunner -FilePath $FilePath `
                -ArgumentList $ArgumentList -Limits $Limits
        } $script:pwsh $arguments $Limits
        $response = & $runner.Handler ([pscustomobject]$Request)
        return [pscustomobject]@{
            Runner = $runner
            Response = $response
            Telemetry = Get-OwnerModelRunnerTelemetry -Runner $runner
        }
    }
}

Describe 'Owner bounded model runner' {
    It 'keeps the public live model launcher unconditionally unavailable' {
        {
            New-OwnerModelProcessRunner -FilePath $script:pwsh
        } | Should -Throw '*owner-model-launch-unavailable*'
    }

    It 'returns success, no-findings, mixed verdicts, and explicit model unknowns' {
        (Invoke-TestProcessRunner -Mode valid).Response.judgment | Should -Be 'violation'
        (Invoke-TestProcessRunner -Mode no-findings).Response.judgment | Should -Be 'compliant'
        (Invoke-TestProcessRunner -Mode valid -Request (
                New-TestModelRequest -Name 'CompliantMethod' -Suffix ('d' * 64)
            )).Response.judgment | Should -Be 'compliant'
        $unknown = Invoke-TestProcessRunner -Mode unknown
        $unknown.Response.judgment | Should -Be 'unknown'
        $unknown.Telemetry.refusalReason | Should -Be 'model-unknown'
    }

    It 'degrades omitted, duplicate, and unknown references without accepting them' -TestCases @(
        @{ Mode = 'omitted'; Expected = 'response-omitted' }
        @{ Mode = 'duplicate'; Expected = 'response-duplicate' }
        @{ Mode = 'unknown-ref'; Expected = 'response-omitted' }
    ) {
        param($Mode, $Expected)
        $run = Invoke-TestProcessRunner -Mode $Mode -Limits (
            New-OwnerModelRunnerLimits -MaximumAttemptsPerUnit 1)
        $run.Response.judgment | Should -Be 'unknown'
        $run.Telemetry.refusalReason | Should -Be $Expected
    }

    It 'rejects malformed marker, JSON, and schema deterministically' -TestCases @(
        @{ Mode = 'malformed-marker'; Expected = 'marker-invalid' }
        @{ Mode = 'malformed-json'; Expected = 'json-invalid' }
        @{ Mode = 'malformed-schema'; Expected = 'schema-invalid' }
    ) {
        param($Mode, $Expected)
        $limits = New-OwnerModelRunnerLimits -MaximumAttemptsPerUnit 1
        $first = Invoke-TestProcessRunner -Mode $Mode -Limits $limits
        $second = Invoke-TestProcessRunner -Mode $Mode -Limits $limits
        $first.Response.judgment | Should -Be 'unknown'
        $first.Telemetry.refusalReason | Should -Be $Expected
        $second.Telemetry.refusalReason | Should -Be $Expected
    }

    It 'fails closed on nonce, input digest, and opaque subject binding mismatch' -TestCases @(
        @{ Mode = 'wrong-nonce' }
        @{ Mode = 'wrong-digest' }
        @{ Mode = 'wrong-subject' }
    ) {
        param($Mode)
        $run = Invoke-TestProcessRunner -Mode $Mode -Limits (
            New-OwnerModelRunnerLimits -MaximumAttemptsPerUnit 3)
        $run.Response.judgment | Should -Be 'unknown'
        $run.Telemetry.attempts | Should -Be 1
        $run.Telemetry.refusalReason | Should -Be 'binding-mismatch'
    }

    It 'caps stdout and stderr floods without exposing child content' -TestCases @(
        @{ Mode = 'stdout-flood' }
        @{ Mode = 'stderr-flood' }
        @{ Mode = 'line-flood' }
    ) {
        param($Mode)
        $run = Invoke-TestProcessRunner -Mode $Mode -Limits (
            New-OwnerModelRunnerLimits -MaximumAttemptsPerUnit 1 `
                -MaximumStdoutBytes 512 -MaximumStderrBytes 512 -MaximumOutputLines 8)
        $run.Response.judgment | Should -Be 'unknown'
        $run.Telemetry.refusalReason | Should -Be 'output-limit'
        ($run.Telemetry | ConvertTo-Json -Depth 8 -Compress) | Should -Not -Match 'secret-value'
    }

    It 'exposes only the bounded capability stimulus and a literal empty tool ceiling' {
        $summaryPath = Join-Path $TestDrive 'envelope-summary.json'
        $run = Invoke-TestProcessRunner -Mode inspect-envelope -StatePath $summaryPath
        $run.Response.judgment | Should -Be 'violation'
        $summary = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json -AsHashtable
        $summary.envelopeKeys | Should -Be @(
            'inputDigest', 'nonce', 'schemaVersion', 'semantics', 'stimulus',
            'subjectBinding', 'toolCeiling'
        )
        $summary.stimulusKeys | Should -Be @(
            'capability', 'construct', 'executionUnitId', 'rule', 'schemaVersion', 'semantics'
        )
        $summary.constructKeys | Should -Be @('attributes', 'kind', 'name', 'snippet')
        @($summary.toolCeiling.context) | Should -Be @('capability-stimulus')
        @($summary.toolCeiling.tools).Count | Should -Be 0
        $summary.toolCeiling.providerWrite | Should -BeFalse
        $summary.toolCeiling.adoWrite | Should -BeFalse
        $summary.toolCeiling.shell | Should -BeFalse
        $summary.toolCeiling.web | Should -BeFalse
        $summary.toolCeiling.delegation | Should -BeFalse
        @($summary.sensitiveEnvironmentNames) | Should -Be @()
        $summary.testOnly | Should -Be '1'
        ($summary | ConvertTo-Json -Depth 8 -Compress) |
            Should -Not -Match '(?i)headCommit|targetCommit|anchor|groupRef|eligibility|delivery'
    }

    It 'bounds early exit and retry attempts while preserving start accounting' {
        $early = Invoke-TestProcessRunner -Mode early-exit -Limits (
            New-OwnerModelRunnerLimits -MaximumAttemptsPerUnit 1)
        $early.Response.judgment | Should -Be 'unknown'
        $early.Telemetry.attempts | Should -Be 1
        $early.Telemetry.modelStarts | Should -Be 1
        $early.Telemetry.refusalReason | Should -Be 'early-exit'

        $counter = Join-Path $TestDrive 'retry-count.txt'
        $retry = Invoke-TestProcessRunner -Mode retry-once -StatePath $counter -Limits (
            New-OwnerModelRunnerLimits -MaximumAttemptsPerUnit 2)
        $retry.Response.judgment | Should -Be 'violation'
        $retry.Telemetry.attempts | Should -Be 2
        $retry.Telemetry.modelStarts | Should -Be 2
        $retry.Telemetry.refusalReason | Should -Be 'none'
        [int](Get-Content -LiteralPath $counter -Raw) | Should -Be 2
    }

    It 'enforces activity, per-call, and total deadlines' {
        $activity = Invoke-TestProcessRunner -Mode timeout -Limits (
            New-OwnerModelRunnerLimits -MaximumAttemptsPerUnit 1 `
                -ActivityDeadlineMilliseconds 100 -PerCallDeadlineMilliseconds 1000 `
                -TotalDeadlineMilliseconds 2000)
        $activity.Response.judgment | Should -Be 'unknown'
        $activity.Telemetry.refusalReason | Should -Be 'activity-timeout'

        $call = Invoke-TestProcessRunner -Mode timeout -Limits (
            New-OwnerModelRunnerLimits -MaximumAttemptsPerUnit 1 `
                -ActivityDeadlineMilliseconds 1000 -PerCallDeadlineMilliseconds 100 `
                -TotalDeadlineMilliseconds 2000)
        $call.Telemetry.refusalReason | Should -Be 'call-timeout'

        $total = Invoke-TestProcessRunner -Mode timeout -Limits (
            New-OwnerModelRunnerLimits -MaximumAttemptsPerUnit 3 `
                -ActivityDeadlineMilliseconds 1000 -PerCallDeadlineMilliseconds 1000 `
                -TotalDeadlineMilliseconds 150)
        $total.Response.judgment | Should -Be 'unknown'
        $total.Telemetry.refusalReason | Should -Be 'total-timeout'
        $total.Telemetry.attempts | Should -Be 1
    }

    It 'contains descendants and closes their process tree on deadline' {
        $pidPath = Join-Path $TestDrive 'descendant.pid'
        $run = Invoke-TestProcessRunner -Mode descendant -StatePath $pidPath -Limits (
            New-OwnerModelRunnerLimits -MaximumAttemptsPerUnit 1 `
                -ActivityDeadlineMilliseconds 1500 -PerCallDeadlineMilliseconds 3000 `
                -TotalDeadlineMilliseconds 4000)
        $run.Response.judgment | Should -Be 'unknown'
        $run.Telemetry.refusalReason | Should -Be 'activity-timeout'
        Test-Path -LiteralPath $pidPath | Should -BeTrue
        $descendantId = [int](Get-Content -LiteralPath $pidPath -Raw)
        { Get-Process -Id $descendantId -ErrorAction Stop } | Should -Throw
    }

    It 'replays exact sanitized bytes through the same validator without a model start' {
        $request = New-TestModelRequest
        $record = New-OwnerModelReplayRecord -Request $request -Judgment violation
        $fixture = New-OwnerModelReplayFixture -Records @($record)
        $runner = New-OwnerModelReplayRunner -Fixture $fixture
        $first = & $runner.Handler ([pscustomobject]$request)
        $second = & $runner.Handler ([pscustomobject]$request)
        $telemetry = Get-OwnerModelRunnerTelemetry -Runner $runner

        $first.judgment | Should -Be 'violation'
        $second | ConvertTo-Json -Compress | Should -BeExactly ($first | ConvertTo-Json -Compress)
        $telemetry.attempts | Should -Be 2
        $telemetry.modelStarts | Should -Be 0
        $telemetry.refusalReason | Should -Be 'none'
        @($fixture.PSObject.Properties.Name) | Should -Be @('Records')
        ($fixture | ConvertTo-Json -Depth 8 -Compress) |
            Should -Not -Match '(?i)filepath|argumentlist|provider|write|shell|web|delegation'
    }

    It 'retains a valid replayed unit when a sibling fixture is malformed' {
        $validRequest = New-TestModelRequest -Suffix ('1' * 64)
        $badRequest = New-TestModelRequest -Suffix ('2' * 64)
        $valid = New-OwnerModelReplayRecord -Request $validRequest -Judgment violation
        $bad = New-OwnerModelReplayRecord -Request $badRequest -Judgment violation `
            -ResponseBytes ([Text.Encoding]::UTF8.GetBytes('not a marker'))
        $runner = New-OwnerModelReplayRunner -Fixture (
            New-OwnerModelReplayFixture -Records @($valid, $bad))

        (& $runner.Handler ([pscustomobject]$validRequest)).judgment | Should -Be 'violation'
        (& $runner.Handler ([pscustomobject]$badRequest)).judgment | Should -Be 'unknown'
        $telemetry = Get-OwnerModelRunnerTelemetry -Runner $runner
        $telemetry.attempts | Should -Be 2
        $telemetry.modelStarts | Should -Be 0
        $telemetry.refusalReason | Should -Be 'marker-invalid'
    }

    It 'emits complete sanitized telemetry through the existing observation execution shape' {
        $request = New-TestModelRequest
        $runner = New-OwnerModelReplayRunner -Fixture (
            New-OwnerModelReplayFixture -Records @(
                New-OwnerModelReplayRecord -Request $request -Judgment violation
            ))
        [void](& $runner.Handler ([pscustomobject]$request))
        $pipelineResult = [ordered]@{
            state = 'complete'
            evidence = [ordered]@{
                evidenceDigest = 'v1:sha256:' + ('9' * 64)
                evidenceUnits = @(
                    [ordered]@{
                        unitId = 'identity'
                        data = [ordered]@{
                            capabilityId = 'owner-example-v2'
                            pullRequestId = 42
                            repositoryId = 'repository-example'
                            sourceCommit = 'a' * 40
                            targetCommit = 'b' * 40
                            targetRef = 'refs/heads/main'
                        }
                    },
                    [ordered]@{
                        unitId = 'rule'
                        data = [ordered]@{
                            repositoryId = 'rules-example'
                            path = '.config/owner-rules.md'
                            commit = 'c' * 40
                            section = 'owner-policy'
                            hash = 'v1:sha256:' + ('d' * 64)
                        }
                    }
                )
            }
            validation = [ordered]@{
                assessments = @(
                    [ordered]@{
                        assessmentId = 'method:r:' + ('e' * 64)
                        state = 'complete'
                    }
                )
            }
            preview = [ordered]@{ findings = @() }
            diagnostics = @()
        }
        $observation = ConvertTo-OwnerV2Observation -PipelineResult $pipelineResult -Runner $runner
        @($observation.execution.Keys) |
            Should -Be @('attempts', 'modelStarts', 'latencyMs', 'refusalReason', 'incompleteReason')
        $observation.execution.attempts | Should -Be 1
        $observation.execution.modelStarts | Should -Be 0
        $observation.execution.latencyMs | Should -BeGreaterOrEqual 0
        $observation.execution.refusalReason | Should -Be 'none'
        $observation.effects.providerWrites | Should -Be 0
        $observation.effects.writeToolInvocations | Should -Be 0
    }
}

Describe 'Owner model runner module surface' {
    It 'exports only bounded runner construction, replay, and telemetry functions' {
        @((Get-Command -Module DevPilot.OwnerModelRunner).Name | Sort-Object) | Should -Be @(
            'Get-OwnerModelRunnerTelemetry',
            'New-OwnerModelProcessRunner',
            'New-OwnerModelReplayFixture',
            'New-OwnerModelReplayRecord',
            'New-OwnerModelReplayRunner',
            'New-OwnerModelRunnerLimits'
        )
    }
}
