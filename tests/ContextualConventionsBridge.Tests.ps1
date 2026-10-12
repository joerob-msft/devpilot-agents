#requires -Version 7.0

BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $repoRoot `
        'src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1') -Force
    Import-Module (Join-Path $repoRoot `
        'src\DevPilot.OwnerAdapters\DevPilot.OwnerAdapters.psd1') -Force
    Import-Module (Join-Path $repoRoot `
        'src\DevPilot.ContextualConventionsBridge\DevPilot.ContextualConventionsBridge.psd1') -Force

    function Get-ContextualTestTextDigest {
        param([Parameter(Mandatory)][string]$Text)
        return 'v1:sha256:' +
            [Convert]::ToHexString(
                [Security.Cryptography.SHA256]::HashData(
                    [Text.Encoding]::UTF8.GetBytes(
                        $Text))).ToLowerInvariant()
    }

    function New-ContextualTestConfig {
        $reviewer =
            New-OwnerAzureDevOpsReviewerIdentity `
                -Id '33333333-3333-3333-3333-333333333333' `
                -Descriptor 'aad.synthetic-service-account' `
                -UniqueName 'service@example.invalid'
        $adapter =
            New-OwnerAzureDevOpsReadOnlyProviderAdapter `
                -Name contextual-bridge-config `
                -ReviewerIdentity $reviewer `
                -Handler { throw 'not invoked' }
        return [ordered]@{
            schemaVersion = 1
            enabled = $false
            readOnly = $true
            dryRun = $true
            organization =
                'https://dev.azure.com/example-org'
            projectName = 'ExampleProject'
            projectId =
                '22222222-2222-2222-2222-222222222222'
            repositoryId =
                '11111111-1111-1111-1111-111111111111'
            expectedAccount = [ordered]@{
                id =
                    '33333333-3333-3333-3333-333333333333'
                descriptor =
                    'aad.synthetic-service-account'
                uniqueName =
                    'service@example.invalid'
            }
            automationMarker =
                '[DevPilot-Automation:v1]'
            rules = @([ordered]@{
                    id =
                        'bpm-contextual-conventions@1'
                    capability =
                        'bpm-contextual-conventions@1'
                })
            contextualRule = [ordered]@{
                repositoryId = 'devpilot-agents'
                path =
                    'src/DevPilot.OwnerCapability/Policy/contextual-conventions.v1.json'
                section =
                    'bpm-contextual-conventions@1'
                hash =
                    'v1:sha256:5dab00b07fadfd3bb16a095da7cd960d00b4cb579cc8392ce5812436654a1cad'
                length = 3498
            }
            toolkit = [ordered]@{
                ref =
                    'refs/heads/contextual-test'
                head = 'a' * 40
                tree = 'b' * 40
            }
            subjectProvider = [ordered]@{
                kind =
                    'azure-devops-read-only-v1'
                organization =
                    'https://dev.azure.com/example-org'
                projectName = 'ExampleProject'
                projectId =
                    '22222222-2222-2222-2222-222222222222'
                repositoryName =
                    'ExampleRepository'
                repositoryId =
                    '11111111-1111-1111-1111-111111111111'
                maximumFiles = 64
                maximumBytes = 16777216
                maximumReads = 128
            }
            discussionProvider = [ordered]@{
                kind =
                    'azure-devops-rest-owner-discussions-v1'
                mappingDigest =
                    $adapter.
                        AzureDevOpsDiscussionMappingDigest
                reviewerIdentity = [ordered]@{
                    id = [string]$reviewer.Id
                    descriptor =
                        [string]$reviewer.Descriptor
                    uniqueName =
                        [string]$reviewer.UniqueName
                    digest =
                        $adapter.
                            AzureDevOpsReviewerIdentityDigest
                }
            }
            capability = [ordered]@{
                id =
                    'bpm-contextual-conventions@1'
                implementationSha256 =
                    'aa316ea3ae651eb996441b56c852b19dee080e30c659e4570946dec24589d208'
            }
            sharedAcquisition = [ordered]@{
                kind =
                    'devpilot-shared-review-acquisition-v1'
                activePrIntakeSha256 =
                    (Get-FileHash (
                        Join-Path $repoRoot `
                            'src\DevPilot.ActivePrIntake\DevPilot.ActivePrIntake.psm1') `
                        -Algorithm SHA256).Hash.
                    ToLowerInvariant()
                contextualBridgeSha256 =
                    (Get-FileHash (
                        Join-Path $repoRoot `
                            'src\DevPilot.ContextualConventionsBridge\DevPilot.ContextualConventionsBridge.psm1') `
                        -Algorithm SHA256).Hash.
                    ToLowerInvariant()
                toolSha256 =
                    (Get-FileHash (
                        Join-Path $repoRoot `
                            'tools\Invoke-SharedReviewAcquisition.ps1') `
                        -Algorithm SHA256).Hash.
                    ToLowerInvariant()
            }
            autoCreateContextualConventionComments =
                $false
            limits = [ordered]@{
                pageSize = 50
                maxPages = 8
                maxPullRequests = 20
                maxHeadsPerRun = 4
                maxReads = 128
                maxSeconds = 30
                maxChangedFiles = 64
                maxChangedLines = 100000
                maxThreads = 100
                maxComments = 500
            }
        }
    }

    function New-ContextualPreparedIntake {
        param(
            [string]$Content =
                'using System.IO; class C { void M() { try { X(); } catch (IOException ex) when (!ex.IsFatal()) { Logger.Error(ex.Message); } } }'
        )
        $head = [ordered]@{
            repositoryId =
                '11111111-1111-1111-1111-111111111111'
            projectId =
                '22222222-2222-2222-2222-222222222222'
            pullRequestId = 42
            sourceRef = 'refs/heads/feature'
            targetRef = 'refs/heads/master'
            sourceCommit = 'c' * 40
            targetCommit = 'd' * 40
            iterationId = 3
            status = 'active'
            isDraft = $false
        }
        $digest =
            Get-ContextualTestTextDigest $Content
        $changes = [ordered]@{
            changedFiles = 1
            changedLines = 1
            entries = @([ordered]@{
                    changeTrackingId = 7
                    path = 'src/Checks.cs'
                    changeType = 'edit'
                    state = 'complete'
                    spans = @([ordered]@{
                            startLine = 1
                            endLine = 1
                            state = 'complete'
                            sourceDigest = $digest
                        })
                    content = $Content
                    byteLength =
                        [Text.Encoding]::UTF8.
                            GetByteCount($Content)
                    sourceDigest = $digest
                })
        }
        $intake = [ordered]@{
            schemaVersion = 1
            kind =
                'devpilot-active-pr-intake-result'
            populationKnown = $true
            inventory = [ordered]@{
                state = 'complete'
                eligible = 1
            }
            counts = [ordered]@{
                error = 0
            }
            heads = @([ordered]@{
                    pullRequestId = 42
                    targetRef =
                        'refs/heads/master'
                    reasonCode = 'selected'
                    declaration = $head
                })
            transientSnapshots = [ordered]@{
                '42' = [ordered]@{
                    head = $head
                    changes = $changes
                    discussions = [ordered]@{
                        threads = @()
                        count = 0
                    }
                    sourceDigest = 'e' * 64
                }
            }
        }
        return [pscustomobject]@{
            Intake = $intake
            Head = $head
        }
    }
}

Describe 'Contextual convention current PR bridge' {
    It 'is default-off with no reads or durable state' {
        $config = New-ContextualTestConfig
        $reads =
            [Collections.Generic.List[string]]::new()
        $provider = {
            param($Operation, $Arguments)
            [void]$reads.Add($Operation)
            throw 'provider should not be read'
        }.GetNewClosure()
        $state = Join-Path $TestDrive `
            'contextual-disabled-state'
        $manifest = Join-Path $TestDrive `
            'contextual-disabled-manifest.json'

        $result =
            Invoke-ContextualConventionsCurrentPrBridge `
                -Config $config -Provider $provider `
                -StateRoot $state `
                -ManifestPath $manifest `
                -RepositoryRoot $repoRoot

        $result.state | Should -BeExactly disabled
        $reads.Count | Should -Be 0
        Test-Path -LiteralPath $state |
            Should -BeFalse
    }

    It 'consumes the prepared shared snapshot and writes one model-free finding' {
        $config = New-ContextualTestConfig
        $config.enabled = $true
        $prepared = New-ContextualPreparedIntake
        $provider = {
            param($Operation, $Arguments)
            if ($Operation -ceq 'Head') {
                return [ordered]@{} +
                    $prepared.Head
            }
            throw "unexpected:$Operation"
        }.GetNewClosure()
        $state = Join-Path $TestDrive `
            'contextual-active-state'
        $manifest = Join-Path $TestDrive `
            'contextual-active-manifest.json'

        $result =
            Invoke-ContextualConventionsCurrentPrBridge `
                -Config $config -Provider $provider `
                -StateRoot $state `
                -ManifestPath $manifest `
                -RepositoryRoot $repoRoot `
                -PreparedIntake $prepared.Intake -Run

        $result.state | Should -BeExactly completed `
            -Because (
                $result.outcomes |
                    ConvertTo-Json -Depth 16 -Compress)
        $result.providerWrites | Should -Be 0
        $result.modelWrites | Should -Be 0
        @($result.records) | Should -HaveCount 1
        $observation =
            Get-Content -LiteralPath (
                [string]$result.outcomes[
                    0].observationPath) -Raw |
                ConvertFrom-Json -AsHashtable `
                    -Depth 64
        $observation.capability |
            Should -BeExactly `
                bpm-contextual-conventions@1
        $observation.execution.modelStarts |
            Should -Be 0
        @($observation.findings) |
            Should -HaveCount 1
        $observation.findings[0].ruleId |
            Should -BeExactly exception-logging
        $observation.findings[0].
            reconciliation.classification |
            Should -BeExactly wouldCreate
    }

    It 'withholds a changed head without provider writes' {
        $config = New-ContextualTestConfig
        $config.enabled = $true
        $prepared = New-ContextualPreparedIntake
        $provider = {
            param($Operation, $Arguments)
            if ($Operation -ceq 'Head') {
                $drifted =
                    [ordered]@{} +
                    $prepared.Head
                $drifted.sourceCommit = 'f' * 40
                return $drifted
            }
            throw "unexpected:$Operation"
        }.GetNewClosure()
        $state = Join-Path $TestDrive `
            'contextual-drift-state'
        $manifest = Join-Path $TestDrive `
            'contextual-drift-manifest.json'

        $result =
            Invoke-ContextualConventionsCurrentPrBridge `
                -Config $config -Provider $provider `
                -StateRoot $state `
                -ManifestPath $manifest `
                -RepositoryRoot $repoRoot `
                -PreparedIntake $prepared.Intake -Run

        $result.state | Should -BeExactly partial
        $result.providerWrites | Should -Be 0
        $result.modelWrites | Should -Be 0
        @($result.outcomes |
            Where-Object state -CEQ unknown).Count |
            Should -BeGreaterThan 0
    }
}
