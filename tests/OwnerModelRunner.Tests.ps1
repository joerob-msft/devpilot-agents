BeforeAll {
    Import-Module "$PSScriptRoot\..\src\DevPilot.OwnerModelRunner\DevPilot.OwnerModelRunner.psd1" -Force
    Import-Module "$PSScriptRoot\..\src\DevPilot.OwnerCapability\DevPilot.OwnerCapability.psd1" -Force

    $script:child = (Resolve-Path "$PSScriptRoot\fixtures\OwnerModelChild.ps1").Path
    $script:acpChild = (Resolve-Path "$PSScriptRoot\fixtures\OwnerAcpChild.ps1").Path
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
        $provider = New-OwnerModelFakeProvider -FilePath $script:pwsh `
            -ArgumentList $arguments
        $runner = New-OwnerModelProcessRunner -Provider $provider -Limits $Limits
        $response = & $runner.Handler ([pscustomobject]$Request)
        return [pscustomobject]@{
            Runner = $runner
            Response = $response
            Telemetry = Get-OwnerModelRunnerTelemetry -Runner $runner
        }
    }

    function Invoke-TestAcpInitialize {
        param(
            [Parameter(Mandatory)][string]$Mode,
            [string]$StatePath,
            [int]$DeadlineMilliseconds = 3000
        )
        $arguments = @('-NoProfile', '-File', $script:acpChild, $Mode)
        if ($StatePath) { $arguments += $StatePath }
        else { $arguments += '-' }
        $provider = New-OwnerModelFakeProvider -FilePath $script:pwsh `
            -ArgumentList $arguments
        return & (Get-Module DevPilot.OwnerModelRunner) {
            param($Provider, $Arguments, $DeadlineMilliseconds)
            $directory = New-OwnerModelAttemptDirectory -Provider $Provider
            try {
                Invoke-OwnerModelAcpInitializePreflight -Provider $Provider `
                    -AttemptDirectory $directory -ArgumentList $Arguments `
                    -DeadlineMilliseconds $DeadlineMilliseconds
            }
            finally {
                if (Test-Path -LiteralPath $directory -PathType Container) {
                    $deadline = [DateTime]::UtcNow.AddSeconds(5)
                    do {
                        try {
                            Remove-Item -LiteralPath $directory -Recurse -Force `
                                -ErrorAction Stop
                            break
                        }
                        catch {
                            if (-not (Test-Path -LiteralPath $directory)) { break }
                            if ([DateTime]::UtcNow -ge $deadline) { throw }
                            Start-Sleep -Milliseconds 50
                        }
                    } while ($true)
                }
                Remove-OwnerModelPrivateLaunchRoot -Provider $Provider
            }
        } $provider $arguments $DeadlineMilliseconds
    }
}

Describe 'Owner bounded model runner' {
    It 'requires explicit opt-in before any real model launch' {
        $provider = New-OwnerCopilotCliModelProvider -Model gpt-5.6-sol `
            -FilePath $script:pwsh -CredentialEnvironmentName GH_TOKEN
        {
            New-OwnerModelProcessRunner -Provider $provider
        } | Should -Throw '*explicit -EnableRealLaunch*'
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

    It 'rejects non-opaque execution-unit identifiers before starting a process' {
        $provider = New-OwnerModelFakeProvider -FilePath $script:pwsh `
            -ArgumentList @('-NoProfile', '-File', $script:child, 'valid', '-')
        $runner = New-OwnerModelProcessRunner -Provider $provider
        {
            & $runner.Handler ([pscustomobject]@{ executionUnitId = 'method:raw-name' })
        } | Should -Throw '*invalid execution-unit reference*'
        (Get-OwnerModelRunnerTelemetry -Runner $runner).attempts | Should -Be 0
    }

    It 'rejects malformed marker, JSON, and schema deterministically' -TestCases @(
        @{ Mode = 'malformed-marker'; Expected = 'marker-invalid' }
        @{ Mode = 'malformed-json'; Expected = 'json-invalid' }
        @{ Mode = 'missing-schema'; Expected = 'schema-invalid' }
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
        @{ Mode = 'wrong-model' }
    ) {
        param($Mode)
        $run = Invoke-TestProcessRunner -Mode $Mode -Limits (
            New-OwnerModelRunnerLimits -MaximumAttemptsPerUnit 3)
        $run.Response.judgment | Should -Be 'unknown'
        $run.Telemetry.attempts | Should -Be 1
        $run.Telemetry.refusalReason | Should -Be 'binding-mismatch'
        $run.Telemetry.records[0].responseBytesBase64 | Should -BeNullOrEmpty
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
            'inputDigest', 'modelIdentity', 'nonce', 'schemaVersion', 'semantics',
            'stimulus', 'subjectBinding', 'toolCeiling'
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
        $summary.currentDirectory | Should -Not -Match [regex]::Escape((Resolve-Path "$PSScriptRoot\..").Path)
        $summary.envelopeFile | Should -Be 'bounded-stimulus.b64'
        $summary.commandLineContainsSnippet | Should -BeFalse
        @($summary.directoryEntries) | Should -Be @(
            'appdata', 'bounded-stimulus.b64', 'home', 'localappdata', 'temp')
        @($summary.environmentNames | Where-Object {
                $_ -match '(?i)(?:token|secret|password|credential|api[_-]?key|github|azure|ado|copilot)'
            }) | Should -Be @()
        ($summary | ConvertTo-Json -Depth 8 -Compress) |
            Should -Not -Match '(?i)headCommit|targetCommit|anchor|groupRef|eligibility|delivery'
    }

    It 'bounds early exit and retry attempts while preserving start accounting' {
        $early = Invoke-TestProcessRunner -Mode early-exit -Limits (
            New-OwnerModelRunnerLimits -MaximumAttemptsPerUnit 1)
        $early.Response.judgment | Should -Be 'unknown'
        $early.Telemetry.attempts | Should -Be 1
        $early.Telemetry.modelStarts | Should -Be 0
        $early.Telemetry.refusalReason | Should -Be 'early-exit'

        $counter = Join-Path $TestDrive 'retry-count.txt'
        $retry = Invoke-TestProcessRunner -Mode retry-once -StatePath $counter -Limits (
            New-OwnerModelRunnerLimits -MaximumAttemptsPerUnit 2)
        $retry.Response.judgment | Should -Be 'violation'
        $retry.Telemetry.attempts | Should -Be 2
        $retry.Telemetry.modelStarts | Should -Be 0
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
        @($total.Telemetry.records | Where-Object processStarted -eq $true).Count | Should -Be 1
    }

    It 'contains descendants and closes their process tree on deadline' {
        $pidPath = Join-Path $TestDrive 'descendant.pid'
        $run = Invoke-TestProcessRunner -Mode descendant -StatePath $pidPath -Limits (
            New-OwnerModelRunnerLimits -MaximumAttemptsPerUnit 1 `
                -ActivityDeadlineMilliseconds 3000 -PerCallDeadlineMilliseconds 5000 `
                -TotalDeadlineMilliseconds 6000)
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

    It 'accepts only a bounded optional rationale' {
        (Invoke-TestProcessRunner -Mode rationale).Response.judgment | Should -Be 'violation'
    }

    It 'synthesizes a model-bound replay marker when model identity is supplied' {
        $request = New-TestModelRequest
        $record = New-OwnerModelReplayRecord -Request $request -Judgment violation `
            -ModelIdentity 'model-example'
        $runner = New-OwnerModelReplayRunner -Fixture (
            New-OwnerModelReplayFixture -Records @($record))

        (& $runner.Handler ([pscustomobject]$request)).judgment | Should -Be 'violation'
    }

    It 'replays the exact fake-process response bytes with equivalent judgment' {
        $request = New-TestModelRequest
        $fake = Invoke-TestProcessRunner -Mode valid -Request $request
        $record = New-OwnerModelReplayRecord -Request $request `
            -Nonce $fake.Telemetry.records[0].nonce `
            -ModelIdentity $fake.Telemetry.provider.modelIdentity `
            -ResponseBytes ([Convert]::FromBase64String(
                $fake.Telemetry.records[0].responseBytesBase64))
        $replay = New-OwnerModelReplayRunner -Fixture (
            New-OwnerModelReplayFixture -Records @($record))

        (& $replay.Handler ([pscustomobject]$request)).judgment |
            Should -Be $fake.Response.judgment
        (Get-OwnerModelRunnerTelemetry -Runner $replay).records[0].responseBytesBase64 |
            Should -BeExactly $fake.Telemetry.records[0].responseBytesBase64
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
        $telemetry.records[1].responseBytesBase64 | Should -BeNullOrEmpty
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

        $indeterminateRunner = New-OwnerSemanticRunner -Name 'indeterminate-start' `
            -Handler { throw 'not invoked' } -TelemetryProvider {
                [ordered]@{
                    attempts = 1
                    modelStarts = 'unknown'
                    latencyMs = 1
                    refusalReason = 'early-exit'
                }
            }
        $indeterminate = ConvertTo-OwnerV2Observation -PipelineResult $pipelineResult `
            -Runner $indeterminateRunner
        $indeterminate.execution.modelStarts | Should -Be 'unknown'
        $indeterminate.measurements.execution.modelStarts.status | Should -Be 'unavailable'
        $indeterminate.measurements.execution.modelStarts.reason |
            Should -Be 'model-start-indeterminate'
    }
}

Describe 'Owner no-tools model provider' {
    It 'selects a credential name without scalar indexing and remains fail-closed when absent' {
        $saved = @{}
        foreach ($name in @('COPILOT_GITHUB_TOKEN', 'GH_TOKEN', 'GITHUB_TOKEN')) {
            $saved[$name] = [Environment]::GetEnvironmentVariable($name)
            [Environment]::SetEnvironmentVariable($name, $null)
        }
        try {
            $absent = New-OwnerCopilotCliModelProvider -Model gpt-5.6-sol `
                -FilePath $script:pwsh
            $absent.CredentialEnvironmentName | Should -Be 'COPILOT_GITHUB_TOKEN'

            $env:GH_TOKEN = 'gho_testcredentialvalue'
            $present = New-OwnerCopilotCliModelProvider -Model gpt-5.6-sol `
                -FilePath $script:pwsh
            $present.CredentialEnvironmentName | Should -Be 'GH_TOKEN'
        }
        finally {
            foreach ($name in $saved.Keys) {
                [Environment]::SetEnvironmentVariable($name, $saved[$name])
            }
        }
    }

    It 'locks the Copilot CLI to an exact prompt-mode empty-tool contract' {
        $provider = New-OwnerCopilotCliModelProvider -Model gpt-5.6-sol `
            -FilePath $script:pwsh -CredentialEnvironmentName GH_TOKEN
        @($provider.ArgumentPrefix) | Should -Be @(
            '--no-ask-user',
            '--disallow-temp-dir',
            '--available-tools=__devpilot_no_such_tool_7f2c17a64a3e4d6b__',
            '--allow-all-tools',
            '--disable-builtin-mcps',
            '--no-custom-instructions',
            '--no-remote',
            '--no-remote-export',
            '--no-auto-update',
            '--no-bash-env',
            '--no-experimental',
            '--no-color',
            '--log-level', 'none',
            '--max-autopilot-continues', '1',
            '--secret-env-vars=COPILOT_GITHUB_TOKEN'
        )
        foreach ($forbidden in @(
                '--acp', '--stdio', '--prompt', '--interactive',
                '--resume', '--continue', '--connect', '--session-id',
                '--allow-all', '--yolo',
                '--additional-mcp-config', '--enable-mcp-server',
                '--plugin-dir', '--agent', '--enable-memory', '--add-dir'
            )) {
            @($provider.ArgumentPrefix) | Should -Not -Contain $forbidden
        }
        Test-Path -LiteralPath $provider.LaunchRoot | Should -BeFalse

        $provider.ArgumentPrefix = @($provider.ArgumentPrefix | ForEach-Object {
                if ($_ -clike '--available-tools=*') { '--available-tools=shell' }
                else { $_ }
            })
        {
            New-OwnerModelProcessRunner -Provider $provider -EnableRealLaunch
        } | Should -Throw '*policy was mutated*'
    }

    It 'uses a strict environment allowlist and maps only the selected credential' {
        $priorGh = $env:GH_TOKEN
        $priorAdo = $env:AZURE_DEVOPS_EXT_PAT
        try {
            $env:GH_TOKEN = 'gho_testcredentialvalue'
            $env:AZURE_DEVOPS_EXT_PAT = 'secret-ado-value'
            $provider = New-OwnerCopilotCliModelProvider -Model gpt-5.6-sol `
                -FilePath $script:pwsh -CredentialEnvironmentName GH_TOKEN
            $module = Get-Module DevPilot.OwnerModelRunner
            $summary = & $module {
                param($Provider)
                $directory = New-OwnerModelAttemptDirectory -Provider $Provider
                try {
                    $environment = Get-OwnerModelProcessEnvironment -Provider $Provider `
                        -AttemptDirectory $directory -IncludeCredential
                    return [ordered]@{
                        environmentNames = @($environment.Keys | Sort-Object)
                        credential = $environment.COPILOT_GITHUB_TOKEN
                        hasSourceCredentialName = $environment.Contains('GH_TOKEN')
                        hasAdoCredential = $environment.Contains('AZURE_DEVOPS_EXT_PAT')
                        workingDirectory = $directory
                    }
                }
                finally {
                    Remove-Item -LiteralPath $directory -Recurse -Force
                }
            } $provider

            $summary.credential | Should -BeExactly 'gho_testcredentialvalue'
            $summary.hasSourceCredentialName | Should -BeFalse
            $summary.hasAdoCredential | Should -BeFalse
            $summary.workingDirectory | Should -Not -Match [regex]::Escape(
                (Resolve-Path "$PSScriptRoot\..").Path)
            ($summary | ConvertTo-Json -Depth 8 -Compress) |
                Should -Not -Match 'secret-ado-value'
        }
        finally {
            $env:GH_TOKEN = $priorGh
            $env:AZURE_DEVOPS_EXT_PAT = $priorAdo
        }
    }

    It 'resolves, publisher-verifies, and privately stages the native Copilot executable' {
        if (-not $IsWindows) {
            Set-ItResult -Skipped -Because 'Authenticode publisher identity is Windows-only.'
            return
        }
        $copilot = @(Get-Command copilot -CommandType Application -ErrorAction SilentlyContinue)
        if ($copilot.Count -ne 1) {
            Set-ItResult -Skipped -Because 'Exactly one native Copilot CLI is not installed.'
            return
        }
        $provider = New-OwnerCopilotCliModelProvider -Model gpt-5.6-sol
        $provider.PublisherIdentity | Should -BeExactly 'verified-github'
        $provider.ExecutableSha256 | Should -Match '^[0-9a-f]{64}$'
        $staged = & (Get-Module DevPilot.OwnerModelRunner) {
            param($Provider)
            $directory = New-OwnerModelAttemptDirectory -Provider $Provider
            try {
                $path = Copy-OwnerModelPinnedExecutable -Provider $Provider `
                    -AttemptDirectory $directory
                [pscustomobject]@{
                    path = $path
                    hash = (Get-OwnerModelFileDigest -Path $path).Substring(10)
                    publisher = Test-OwnerCopilotPublisherIdentity -Path $path
                }
            }
            finally {
                if (Test-Path -LiteralPath $directory -PathType Container) {
                    Remove-Item -LiteralPath $directory -Recurse -Force
                }
                Remove-OwnerModelPrivateLaunchRoot -Provider $Provider
            }
        } $provider
        $staged.path | Should -Not -BeExactly $provider.FilePath
        $staged.hash | Should -BeExactly $provider.ExecutableSha256
        $staged.publisher | Should -BeTrue
    }

    It 'places only a bounded credential-free stimulus in the supported prompt argument' {
        $prior = $env:GH_TOKEN
        try {
            $env:GH_TOKEN = 'gho_testcredentialvalue'
            $provider = New-OwnerCopilotCliModelProvider -Model gpt-5.6-sol `
                -FilePath $script:pwsh -CredentialEnvironmentName GH_TOKEN
            $summary = & (Get-Module DevPilot.OwnerModelRunner) {
                param($Provider)
                $directory = New-OwnerModelAttemptDirectory -Provider $Provider
                try {
                    $json = '{"nonce":"bounded-nonce","stimulus":{"rule":{"content":"generic rule"},"construct":{"name":"GenericMethod"},"executionUnitId":"unit:' + ('a' * 64) + '"}}'
                    $envelope = ConvertTo-OwnerModelBase64Url -Bytes (
                        [Text.Encoding]::UTF8.GetBytes($json))
                    $invocation = New-OwnerModelInvocation -Provider $Provider `
                        -EnvelopeBase64 $envelope -AttemptDirectory $directory `
                        -IncludeCredential
                    [ordered]@{
                        argumentsBeforePrompt = @($invocation.ArgumentList[0..(
                                    $invocation.ArgumentList.Count - 2)])
                        prompt = [string]$invocation.ArgumentList[-1]
                        directoryEntries = @(
                            Get-ChildItem -LiteralPath $directory -Force |
                                Select-Object -ExpandProperty Name |
                                Sort-Object)
                        invocationDigest = $invocation.InvocationDigest
                    }
                }
                finally {
                    Remove-Item -LiteralPath $directory -Recurse -Force
                    Remove-OwnerModelPrivateLaunchRoot -Provider $Provider
                }
            } $provider

            $summary.argumentsBeforePrompt[-1] | Should -BeExactly '--prompt'
            $summary.argumentsBeforePrompt[-3..-2] | Should -Be @('--model', 'gpt-5.6-sol')
            $summary.prompt | Should -Match 'BOUNDED_STIMULUS_JSON'
            $summary.prompt | Should -Match 'GenericMethod'
            $summary.prompt | Should -Not -Match 'gho_testcredentialvalue'
            [Text.Encoding]::UTF8.GetByteCount($summary.prompt) | Should -BeLessOrEqual 12288
            @($summary.directoryEntries) | Should -Be @(
                'appdata', 'home', 'localappdata', 'temp')
            $summary.invocationDigest | Should -Match '^v1:sha256:[0-9a-f]{64}$'
        }
        finally {
            $env:GH_TOKEN = $prior
        }
    }

    It 'rejects oversized or credential-bearing prompts without echoing them' -TestCases @(
        @{ Content = 'gho_testcredentialvalue'; Expected = '*provider credential*' }
        @{ Content = ('x' * 20000); Expected = '*byte limit*' }
    ) {
        param($Content, $Expected)
        $prior = $env:GH_TOKEN
        try {
            $env:GH_TOKEN = 'gho_testcredentialvalue'
            $provider = New-OwnerCopilotCliModelProvider -Model gpt-5.6-sol `
                -FilePath $script:pwsh -CredentialEnvironmentName GH_TOKEN
            $message = & (Get-Module DevPilot.OwnerModelRunner) {
                param($Provider, $Content)
                $directory = New-OwnerModelAttemptDirectory -Provider $Provider
                try {
                    $json = ConvertTo-Json -Compress -InputObject @{
                        stimulus = @{ construct = @{ snippet = $Content } }
                    }
                    $envelope = ConvertTo-OwnerModelBase64Url -Bytes (
                        [Text.Encoding]::UTF8.GetBytes($json))
                    try {
                        [void](New-OwnerModelInvocation -Provider $Provider `
                                -EnvelopeBase64 $envelope -AttemptDirectory $directory `
                                -IncludeCredential)
                        'unexpected-success'
                    }
                    catch {
                        $_.Exception.Message
                    }
                }
                finally {
                    Remove-Item -LiteralPath $directory -Recurse -Force
                    Remove-OwnerModelPrivateLaunchRoot -Provider $Provider
                }
            } $provider $Content
            $message | Should -BeLike $Expected
            $message | Should -Not -Match [regex]::Escape($Content)
        }
        finally {
            $env:GH_TOKEN = $prior
        }
    }

    It 'negotiates only ACP v1 with no client file, terminal, or auth capability' {
        $summaryPath = Join-Path $TestDrive 'acp-initialize.json'
        $probe = Invoke-TestAcpInitialize -Mode valid -StatePath $summaryPath
        $probe.protocolVersion | Should -Be 1
        $probe.agentVersion | Should -BeExactly '1.0.79'
        $probe.loadSession | Should -BeFalse
        @($probe.sessionCapabilities) | Should -Be @('close')
        $probe.modelCalls | Should -Be 0
        $probe.stdoutDigest | Should -Match '^v1:sha256:[0-9a-f]{64}$'
        $probe.stderrDigest | Should -BeExactly (
            'v1:sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855')

        $summary = Get-Content -LiteralPath $summaryPath -Raw |
            ConvertFrom-Json -AsHashtable
        $summary.method | Should -BeExactly 'initialize'
        $summary.protocolVersion | Should -Be 1
        $summary.clientCapabilities.fs.readTextFile | Should -BeFalse
        $summary.clientCapabilities.fs.writeTextFile | Should -BeFalse
        $summary.clientCapabilities.terminal | Should -BeFalse
        $summary.clientCapabilities.auth.terminal | Should -BeFalse
        $summary.commandLine | Should -Not -Match 'private-source-stimulus'
        @($summary.environmentNames | Where-Object {
                $_ -match '(?i)(?:token|secret|password|credential|api[_-]?key|github|azure|ado|copilot)'
            }) | Should -Be @()
    }

    It 'reports ACP session history capabilities without exercising them' {
        $probe = Invoke-TestAcpInitialize -Mode persistent
        $probe.loadSession | Should -BeTrue
        @($probe.sessionCapabilities) | Should -Be @('close', 'list')
        $probe.modelCalls | Should -Be 0
    }

    It 'rejects malformed, misbound, flooding, disconnecting, and stalled ACP peers' -TestCases @(
        @{ Mode = 'wrong-id'; Pattern = '*binding did not match*'; Deadline = 3000 }
        @{ Mode = 'wrong-version'; Pattern = '*did not select version 1*'; Deadline = 3000 }
        @{ Mode = 'malformed'; Pattern = '*JSON*'; Deadline = 3000 }
        @{ Mode = 'bad-utf8'; Pattern = '*Unable to translate bytes*'; Deadline = 3000 }
        @{ Mode = 'duplicate-property'; Pattern = '*duplicate JSON property*'; Deadline = 3000 }
        @{ Mode = 'extra-message'; Pattern = '*unexpected protocol message count*'; Deadline = 3000 }
        @{ Mode = 'stdout-flood'; Pattern = '*fixed limit*'; Deadline = 3000 }
        @{ Mode = 'stderr-flood'; Pattern = '*fixed limit*'; Deadline = 3000 }
        @{ Mode = 'disconnect'; Pattern = '*exited before responding*'; Deadline = 3000 }
        @{ Mode = 'timeout'; Pattern = '*timed out*'; Deadline = 100 }
    ) {
        param($Mode, $Pattern, $Deadline)
        {
            Invoke-TestAcpInitialize -Mode $Mode -DeadlineMilliseconds $Deadline
        } | Should -Throw $Pattern
    }

    It 'reports only digest-safe ACP failures' {
        $message = try {
            Invoke-TestAcpInitialize -Mode stderr-flood
            'unexpected-success'
        }
        catch {
            $_.Exception.Message
        }
        $message | Should -BeExactly 'ACP initialize output exceeded its fixed limit.'
        $message | Should -Not -Match 'private-diagnostic'
    }

    It 'contains an ACP descendant when initialization times out' {
        $pidPath = Join-Path $TestDrive 'acp-descendant.pid'
        {
            Invoke-TestAcpInitialize -Mode descendant -StatePath $pidPath `
                -DeadlineMilliseconds 1500
        } | Should -Throw '*timed out*'
        $descendantPid = [int](Get-Content -LiteralPath $pidPath -Raw)
        Start-Sleep -Milliseconds 200
        Get-Process -Id $descendantPid -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }

    It 'detects executable hash policy mutation before starting a child' {
        $provider = New-OwnerModelFakeProvider -FilePath $script:pwsh `
            -ArgumentList @('-NoProfile', '-File', $script:acpChild, 'valid', '-')
        $provider.ExecutableSha256 = '0' * 64
        {
            New-OwnerModelProcessRunner -Provider $provider
        } | Should -Throw '*executable hash changed after construction*'
    }

    It 'uses a stable invocation digest bound to the private stimulus bytes' {
        $provider = New-OwnerModelFakeProvider -FilePath $script:pwsh `
            -ArgumentList @('-NoProfile', '-File', $script:child, 'valid', '-')
        $digests = & (Get-Module DevPilot.OwnerModelRunner) {
            param($Provider)
            $values = [Collections.Generic.List[string]]::new()
            foreach ($envelope in @('same-private-stimulus', 'same-private-stimulus', 'different')) {
                $directory = New-OwnerModelAttemptDirectory -Provider $Provider
                try {
                    $invocation = New-OwnerModelInvocation -Provider $Provider `
                        -EnvelopeBase64 $envelope -AttemptDirectory $directory
                    [void]$values.Add($invocation.InvocationDigest)
                }
                finally {
                    Remove-Item -LiteralPath $directory -Recurse -Force
                    Remove-OwnerModelPrivateLaunchRoot -Provider $Provider
                }
            }
            return @($values)
        } $provider

        $digests[0] | Should -BeExactly $digests[1]
        $digests[0] | Should -Not -BeExactly $digests[2]
    }

    It 'reports prompt-mode preflight unavailable when native provider identity is unproven' {
        $prior = $env:GH_TOKEN
        try {
            $env:GH_TOKEN = 'gho_testcredentialvalue'
            $provider = New-OwnerCopilotCliModelProvider -Model gpt-5.6-sol `
                -FilePath $script:pwsh -CredentialEnvironmentName GH_TOKEN
            $preflight = Test-OwnerModelProviderPreflight -Provider $provider
            $preflight.available | Should -BeFalse
            $preflight.reason | Should -Be 'copilot-cli-publisher-identity-unproven'
            @($preflight.effectiveTools).Count | Should -Be 0
            $preflight.promptTransport | Should -BeExactly 'argv'
            $preflight.localProcessMetadataExposure | Should -BeTrue
            $preflight.modelCalls | Should -Be 0
            $preflight.providerWrites | Should -Be 0
            Test-Path -LiteralPath $provider.LaunchRoot | Should -BeFalse
            {
                New-OwnerModelProcessRunner -Provider $provider -EnableRealLaunch
            } | Should -Throw '*publisher-identity-unproven*'
        }
        finally {
            $env:GH_TOKEN = $prior
        }
    }

    It 'reports available and unavailable credential states for a compatible native CLI' {
        if (-not $IsWindows) {
            Set-ItResult -Skipped -Because 'The native publisher check is Windows-only.'
            return
        }
        $copilot = @(Get-Command copilot -CommandType Application -ErrorAction SilentlyContinue)
        if ($copilot.Count -ne 1) {
            Set-ItResult -Skipped -Because 'Exactly one native Copilot CLI is not installed.'
            return
        }
        $saved = @{}
        foreach ($name in @('COPILOT_GITHUB_TOKEN', 'GH_TOKEN', 'GITHUB_TOKEN')) {
            $saved[$name] = [Environment]::GetEnvironmentVariable($name)
            [Environment]::SetEnvironmentVariable($name, $null)
        }
        try {
            $provider = New-OwnerCopilotCliModelProvider -Model gpt-5.6-sol `
                -CredentialEnvironmentName GH_TOKEN
            $missing = Test-OwnerModelProviderPreflight -Provider $provider
            $missing.available | Should -BeFalse
            $missing.reason | Should -BeExactly 'copilot-cli-credential-unavailable'

            $env:GH_TOKEN = 'gho_testcredentialvalue'
            $available = Test-OwnerModelProviderPreflight -Provider $provider
            $available.available | Should -BeTrue
            $available.reason | Should -BeExactly 'available-with-local-process-metadata-risk'
            $available.cliVersion | Should -Match '^1\.0\.(?:79|8[0-9])'
            @($available.effectiveTools).Count | Should -Be 0
            $available.localProcessMetadataExposure | Should -BeTrue
            $available.atomicProcessContainment | Should -BeFalse
            $available.modelCalls | Should -Be 0
            $available.providerWrites | Should -Be 0
        }
        finally {
            foreach ($name in $saved.Keys) {
                [Environment]::SetEnvironmentVariable($name, $saved[$name])
            }
        }
    }

    It 'rejects a linked launch root instead of following it' {
        $target = Join-Path $TestDrive 'launch-target'
        $link = Join-Path $TestDrive 'launch-link'
        New-Item -ItemType Directory -Path $target | Out-Null
        $created = $false
        try {
            if ($IsWindows) {
                New-Item -ItemType Junction -Path $link -Target $target -ErrorAction Stop | Out-Null
            }
            else {
                New-Item -ItemType SymbolicLink -Path $link -Target $target -ErrorAction Stop | Out-Null
            }
            $created = $true
        }
        catch {
            Set-ItResult -Skipped -Because 'This host cannot create a test link.'
        }
        if ($created) {
            {
                New-OwnerModelFakeProvider -FilePath $script:pwsh -LaunchRoot $link
            } | Should -Throw '*must not be a link or reparse point*'
        }
    }

    It 'reports fake process starts as measured zero model calls with replay-grade provenance' {
        $run = Invoke-TestProcessRunner -Mode valid
        $run.Telemetry.attempts | Should -Be 1
        $run.Telemetry.modelStarts | Should -Be 0
        $run.Telemetry.modelCalls | Should -Be 0
        $run.Telemetry.providerWrites | Should -Be 0
        @($run.Telemetry.effectiveTools).Count | Should -Be 0
        $run.Telemetry.provider.kind | Should -Be 'fake-process'
        $run.Telemetry.provider.promptTransport | Should -BeExactly 'private-file'
        $run.Telemetry.provider.localProcessMetadataExposure | Should -BeFalse
        $run.Telemetry.policy.availableTools.Count | Should -Be 0
        $run.Telemetry.policy.providerWrite | Should -BeFalse
        $run.Telemetry.records[0].processStarted | Should -BeTrue
        $run.Telemetry.records[0].modelStarted | Should -BeFalse
        $run.Telemetry.records[0].inputDigest | Should -Match '^v1:sha256:[0-9a-f]{64}$'
        $run.Telemetry.records[0].nonce | Should -Match '^[0-9a-f]{36}$'
        $run.Telemetry.records[0].subjectBinding | Should -Match '^v1:sha256:[0-9a-f]{64}$'
        $run.Telemetry.records[0].stdoutDigest | Should -Match '^v1:sha256:[0-9a-f]{64}$'
        $run.Telemetry.records[0].stderrDigest | Should -Match '^v1:sha256:[0-9a-f]{64}$'
        $run.Telemetry.records[0].timeout | Should -Be 'none'
        $run.Telemetry.records[0].responseBytesBase64 | Should -Not -BeNullOrEmpty
    }
}

Describe 'Owner model runner module surface' {
    It 'exports only bounded runner construction, replay, and telemetry functions' {
        @((Get-Command -Module DevPilot.OwnerModelRunner).Name | Sort-Object) | Should -Be @(
            'Get-OwnerModelRunnerTelemetry',
            'New-OwnerCopilotCliModelProvider',
            'New-OwnerModelFakeProvider',
            'New-OwnerModelProcessRunner',
            'New-OwnerModelReplayFixture',
            'New-OwnerModelReplayRecord',
            'New-OwnerModelReplayRunner',
            'New-OwnerModelRunnerLimits',
            'Test-OwnerModelProviderPreflight'
        )
    }
}
