#requires -Version 7.0

BeforeAll {
    $repo = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $repo `
        'src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1') -Force
    Import-Module (Join-Path $repo `
        'src\DevPilot.OwnerAdapters\DevPilot.OwnerAdapters.psd1') -Force
    Import-Module (Join-Path $repo `
        'src\DevPilot.NamedAreEqualBridge\DevPilot.NamedAreEqualBridge.psd1') -Force
    Import-Module (Join-Path $repo `
        'src\DevPilot.ActivePrIntake\DevPilot.ActivePrIntake.psd1') -Force

    function Get-TestTextDigest {
        param([AllowEmptyString()][string]$Text)
        return 'v1:sha256:' + [Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData(
                [Text.Encoding]::UTF8.GetBytes($Text))).
            ToLowerInvariant()
    }

    function New-TestConfig {
        $reviewer = New-OwnerAzureDevOpsReviewerIdentity `
            -Id '33333333-3333-3333-3333-333333333333' `
            -Descriptor 'aad.synthetic-service-account' `
            -UniqueName 'service@example.invalid'
        $adapter = New-OwnerAzureDevOpsReadOnlyProviderAdapter `
            -Name 'safe-zero-span-config' `
            -ReviewerIdentity $reviewer `
            -Handler { throw 'not invoked' }
        return [ordered]@{
            schemaVersion = 1
            enabled = $true
            readOnly = $true
            dryRun = $true
            organization = 'https://dev.azure.com/example-org'
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
                uniqueName = 'service@example.invalid'
            }
            automationMarker = '[DevPilot-Automation:v1]'
            rules = @([ordered]@{
                    id =
                        'bpm-named-areequal-arguments@1'
                    capability =
                        'bpm-named-areequal-arguments@1'
                })
            namedRule = [ordered]@{
                repositoryId = 'devpilot-agents'
                path =
                    'src/DevPilot.OwnerCapability/Policy/named-areequal-arguments.v1.txt'
                section =
                    'bpm-named-areequal-arguments@1'
                hash =
                    'v1:sha256:8b9fa35bd2bc96e9f0dbfc878806b540603ab4f255ddf41bf120311913b831f4'
                length = 653
            }
            toolkit = [ordered]@{
                ref = 'refs/heads/safe-zero-span'
                head = 'a' * 40
                tree = 'b' * 40
            }
            subjectProvider = [ordered]@{
                kind = 'azure-devops-read-only-v1'
                organization =
                    'https://dev.azure.com/example-org'
                projectName = 'ExampleProject'
                projectId =
                    '22222222-2222-2222-2222-222222222222'
                repositoryName = 'ExampleRepository'
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
                    $adapter.AzureDevOpsDiscussionMappingDigest
                reviewerIdentity = [ordered]@{
                    id = [string]$reviewer.Id
                    descriptor =
                        [string]$reviewer.Descriptor
                    uniqueName =
                        [string]$reviewer.UniqueName
                    digest =
                        $adapter.AzureDevOpsReviewerIdentityDigest
                }
            }
            capability = [ordered]@{
                id =
                    'bpm-named-areequal-arguments@1'
                implementationSha256 =
                    '7ed3583591b43dbb351292ea9a37a53fc32fc9f0fd3403c821e3209310598e3a'
            }
            sharedAcquisition = [ordered]@{
                kind =
                    'devpilot-shared-review-acquisition-v1'
                activePrIntakeSha256 =
                    (Get-FileHash (Join-Path $repo `
                        'src\DevPilot.ActivePrIntake\DevPilot.ActivePrIntake.psm1') `
                        -Algorithm SHA256).Hash.
                        ToLowerInvariant()
                namedBridgeSha256 =
                    (Get-FileHash (Join-Path $repo `
                        'src\DevPilot.NamedAreEqualBridge\DevPilot.NamedAreEqualBridge.psm1') `
                        -Algorithm SHA256).Hash.
                        ToLowerInvariant()
                toolSha256 =
                    (Get-FileHash (Join-Path $repo `
                        'tools\Invoke-SharedReviewAcquisition.ps1') `
                        -Algorithm SHA256).Hash.
                        ToLowerInvariant()
            }
            autoCreateNamedAreEqualComments =
                $false
            limits = [ordered]@{
                pageSize = 50
                maxPages = 8
                maxPullRequests = 20
                maxHeadsPerRun = 2
                maxReads = 128
                maxSeconds = 30
                maxChangedFiles = 64
                maxChangedLines = 5000
                maxThreads = 100
                maxComments = 500
            }
        }
    }

    function New-TestHead {
        return [ordered]@{
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
    }

    function New-TestPreparedIntake {
        param(
            [Parameter(Mandatory)]
            [Collections.IDictionary]$Entry
        )

        $head = New-TestHead
        $changedLines = 0L
        foreach ($span in @($Entry.spans)) {
            $changedLines +=
                [long]$span.endLine -
                [long]$span.startLine + 1
        }
        $snapshot = [ordered]@{
            schemaVersion = 1
            kind = 'active-pr-transient-snapshot'
            generation = 'e' * 32
            head = $head
            changes = [ordered]@{
                changedFiles = 1
                changedLines = $changedLines
                entries = @($Entry)
            }
            discussions = [ordered]@{
                count = 0
                threads = @()
            }
            sourceDigest = 'f' * 64
        }
        return [ordered]@{
            schemaVersion = 1
            kind = 'active-pr-intake-cohort'
            generation = 'e' * 32
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
                    targetRef = 'refs/heads/master'
                    reasonCode = 'rules-incomplete'
                    declaration = $head
                })
            transientSnapshots = [ordered]@{
                '42' = $snapshot
            }
        }
    }

    function Invoke-TestBridge {
        param(
            [Parameter(Mandatory)]
            [Collections.IDictionary]$Entry,
            [Parameter(Mandatory)]
            [string]$Name
        )

        $head = New-TestHead
        return Invoke-NamedAreEqualCurrentPrBridge `
            -Config (New-TestConfig) `
            -Provider {
                param($Operation, $Request)
                if ($Operation -ceq 'Head') {
                    return [ordered]@{} + $head
                }
                throw 'prepared intake must not read'
            }.GetNewClosure() `
            -PreparedIntake (
                New-TestPreparedIntake -Entry $Entry) `
            -StateRoot (
                Join-Path $TestDrive "$Name-state") `
            -ManifestPath (
                Join-Path $TestDrive "$Name-manifest.json") `
            -RepositoryRoot $repo -Run
    }
}

Describe 'Safe zero-span subset' {
    It 'derives only the authorized fixed classifications' {
        $module = Get-Module DevPilot.ActivePrIntake
        $identical = & $module {
            New-DevPilotChangeDerivation `
                -ChangeType edit -IsText $true `
                -Deleted $false -Renamed $false `
                -SourceContent 'same' `
                -TargetContent 'same' -Spans @() `
                -SourceCommit ('c' * 40) `
                -TargetCommit ('d' * 40)
        }
        $identical.classification |
            Should -BeExactly 'identical-content'
        $identical.sourceContentSha256 |
            Should -BeExactly (
                $identical.targetContentSha256)

        $caseChanged = & $module {
            New-DevPilotChangeDerivation `
                -ChangeType edit -IsText $true `
                -Deleted $false -Renamed $false `
                -SourceContent 'SAME' `
                -TargetContent 'same' -Spans @() `
                -SourceCommit ('c' * 40) `
                -TargetCommit ('d' * 40)
        }
        $caseChanged.classification |
            Should -BeExactly 'derivation-unknown'

        $rename = & $module {
            New-DevPilotChangeDerivation `
                -ChangeType rename -IsText $true `
                -Deleted $false -Renamed $true `
                -SourceContent 'same' `
                -TargetContent 'same' -Spans @() `
                -SourceCommit ('c' * 40) `
                -TargetCommit ('d' * 40)
        }
        $rename.classification |
            Should -BeExactly 'derivation-unknown'

        $deleted = & $module {
            New-DevPilotChangeDerivation `
                -ChangeType delete -IsText $true `
                -Deleted $true -Renamed $false `
                -SourceContent '' -TargetContent '' `
                -Spans @() `
                -SourceCommit ('c' * 40) `
                -TargetCommit ('d' * 40)
        }
        $deleted.classification |
            Should -BeExactly 'deletion-only'

        $addedEmpty = & $module {
            New-DevPilotChangeDerivation `
                -ChangeType add -IsText $true `
                -Deleted $false -Renamed $false `
                -SourceContent '' -TargetContent '' `
                -Spans @([ordered]@{
                        startLine = 1
                        endLine = 1
                    }) `
                -SourceCommit ('c' * 40) `
                -TargetCommit ('d' * 40)
        }
        $addedEmpty.classification |
            Should -BeExactly 'current-lines'
        $addedEmpty.currentLineCount |
            Should -Be 1
    }

    It 'completes proven identical current content with zero findings' {
        $content = 'class Identical {}'
        $digest = Get-TestTextDigest $content
        $entry = [ordered]@{
            path = 'tests/Identical.cs'
            changeType = 'edit'
            state = 'complete'
            spans = @()
            content = $content
            byteLength =
                [Text.Encoding]::UTF8.GetByteCount(
                    $content)
            sourceDigest = $digest
            derivation = [ordered]@{
                schemaVersion = 1
                kind =
                    'devpilot-current-line-derivation-v1'
                producer = 'active-pr-intake-v1'
                state = 'complete'
                classification =
                    'identical-content'
                changeType = 'modified'
                pathRelation = 'same-path'
                sourceCommit = 'c' * 40
                targetCommit = 'd' * 40
                sourceContentState = 'available'
                targetContentState = 'available'
                sourceContentSha256 = $digest
                targetContentSha256 = $digest
                sourceByteLength =
                    [Text.Encoding]::UTF8.
                        GetByteCount($content)
                targetByteLength =
                    [Text.Encoding]::UTF8.
                        GetByteCount($content)
                spanCount = 0
                currentLineCount = 0
            }
        }
        $filtered = & (
            Get-Module DevPilot.NamedAreEqualBridge) {
            param($InputEntry, $InputHead)
            Get-NamedBridgeRelevantChangeSet `
                -ChangeSet ([ordered]@{
                    changedFiles = 1
                    changedLines = 0
                    entries = @($InputEntry)
                }) `
                -Head $InputHead
        } $entry (New-TestHead)
        $filtered.changedFiles | Should -Be 0
        $entryProof = & (
            Get-Module DevPilot.NamedAreEqualBridge) {
            param(
                $InputHead,
                $InputConfig,
                $Snapshot)
            Assert-NamedBridgeHead `
                -Expected $InputHead `
                -Actual $Snapshot.head
            $manifestEntry =
                New-NamedBridgeManifestEntry `
                    -Head $InputHead `
                    -Config $InputConfig `
                    -SharedSnapshotDigest (
                        [string]$Snapshot.sourceDigest)
            return $manifestEntry
        } (New-TestHead) (New-TestConfig) (
            (New-TestPreparedIntake `
                -Entry $entry).
            transientSnapshots['42'])
        $entryProof.subject.pullRequestId |
            Should -Be 42
        $result = Invoke-TestBridge `
            -Entry $entry -Name identical

        $result.state | Should -BeExactly 'completed' `
            -Because ($result |
                ConvertTo-Json -Depth 20 -Compress)
        $result.records | Should -HaveCount 1
        $result.records[0].state |
            Should -BeExactly 'completed'
        $observation = Get-ChildItem `
            -LiteralPath (
                Join-Path $TestDrive 'identical-state') `
            -Recurse -File `
            -Filter "$($result.records[0].identity).json" |
            Where-Object {
                $_.Directory.Name -ceq 'observations'
            } |
            Select-Object -First 1 |
            ForEach-Object {
                Get-Content -LiteralPath (
                    $_.FullName) -Raw |
                ConvertFrom-Json -AsHashtable `
                    -Depth 32
            }
        $observation.findingsComplete |
            Should -BeTrue
        $observation.findings | Should -HaveCount 0
        $observation.effects.providerWrites |
            Should -Be 0
    }

    It 'completes a proven deleted whole CSharp file with zero findings' {
        $entry = [ordered]@{
            path = 'tests/Deleted.cs'
            changeType = 'delete'
            state = 'complete'
            spans = @()
            content = ''
            byteLength = 0
            sourceDigest = Get-TestTextDigest ''
            derivation = [ordered]@{
                schemaVersion = 1
                kind =
                    'devpilot-current-line-derivation-v1'
                producer = 'active-pr-intake-v1'
                state = 'complete'
                classification = 'deletion-only'
                changeType = 'deleted'
                pathRelation = 'same-path'
                sourceCommit = 'c' * 40
                targetCommit = 'd' * 40
                sourceContentState =
                    'absent-deleted'
                targetContentState =
                    'not-read-deleted'
                sourceContentSha256 =
                    Get-TestTextDigest ''
                targetContentSha256 = 'unknown'
                sourceByteLength = 0
                targetByteLength = 0
                spanCount = 0
                currentLineCount = 0
            }
        }
        $filtered = & (
            Get-Module DevPilot.NamedAreEqualBridge) {
            param($InputEntry, $InputHead)
            Get-NamedBridgeRelevantChangeSet `
                -ChangeSet ([ordered]@{
                    changedFiles = 1
                    changedLines = 0
                    entries = @($InputEntry)
                }) `
                -Head $InputHead
        } $entry (New-TestHead)
        $filtered.changedFiles | Should -Be 0
        $result = Invoke-TestBridge `
            -Entry $entry -Name deleted

        $result.state | Should -BeExactly 'completed' `
            -Because ($result |
                ConvertTo-Json -Depth 20 -Compress)
        $result.records[0].state |
            Should -BeExactly 'completed'
    }

    It 'refuses missing or inconsistent proof instead of hiding CSharp evidence' {
        $content = 'class Unknown {}'
        $base = [ordered]@{
            path = 'tests/Unknown.cs'
            changeType = 'edit'
            state = 'complete'
            spans = @()
            content = $content
            byteLength =
                [Text.Encoding]::UTF8.GetByteCount(
                    $content)
            sourceDigest =
                Get-TestTextDigest $content
        }
        $missing = Invoke-TestBridge `
            -Entry $base -Name missing
        $missing.state | Should -BeExactly 'partial'
        $missing.records | Should -HaveCount 0
        $missing.outcomes[0].reason |
            Should -BeExactly 'acquisition-incomplete'

        $forged = $base |
            ConvertTo-Json -Depth 16 |
            ConvertFrom-Json -AsHashtable `
                -Depth 16
        $forged.derivation = [ordered]@{
            schemaVersion = 1
            kind =
                'devpilot-current-line-derivation-v1'
            producer = 'active-pr-intake-v1'
            state = 'complete'
            classification = 'identical-content'
            changeType = 'modified'
            pathRelation = 'same-path'
            sourceCommit = 'c' * 40
            targetCommit = 'd' * 40
            sourceContentState = 'available'
            targetContentState = 'available'
            sourceContentSha256 =
                Get-TestTextDigest $content
            targetContentSha256 =
                Get-TestTextDigest 'different'
            sourceByteLength =
                [Text.Encoding]::UTF8.
                    GetByteCount($content)
            targetByteLength = 9
            spanCount = 0
            currentLineCount = 0
        }
        $inconsistent = Invoke-TestBridge `
            -Entry $forged -Name inconsistent
        $inconsistent.state |
            Should -BeExactly 'partial'
        $inconsistent.records | Should -HaveCount 0
    }

    It 'refuses unsafe repository paths before any known-empty filtering' {
        $content = 'class SafePath {}'
        $digest = Get-TestTextDigest $content
        $entry = [ordered]@{
            path = 'tests/SafePath.cs'
            changeType = 'edit'
            state = 'complete'
            spans = @()
            content = $content
            byteLength =
                [Text.Encoding]::UTF8.
                    GetByteCount($content)
            sourceDigest = $digest
            derivation = [ordered]@{
                schemaVersion = 1
                kind =
                    'devpilot-current-line-derivation-v1'
                producer = 'active-pr-intake-v1'
                state = 'complete'
                classification =
                    'identical-content'
                changeType = 'modified'
                pathRelation = 'same-path'
                sourceCommit = 'c' * 40
                targetCommit = 'd' * 40
                sourceContentState = 'available'
                targetContentState = 'available'
                sourceContentSha256 = $digest
                targetContentSha256 = $digest
                sourceByteLength =
                    [Text.Encoding]::UTF8.
                        GetByteCount($content)
                targetByteLength =
                    [Text.Encoding]::UTF8.
                        GetByteCount($content)
                spanCount = 0
                currentLineCount = 0
            }
        }
        foreach ($unsafePath in @(
                '../../escape.cs',
                '/rooted.cs',
                'C:\rooted.cs',
                'tests//double.cs',
                'tests/./dot.cs',
                'tests/../parent.cs',
                ' tests/space.cs',
                "tests/control`n.cs")) {
            $unsafe = $entry |
                ConvertTo-Json -Depth 16 |
                ConvertFrom-Json -AsHashtable `
                    -Depth 16
            $unsafe.path = $unsafePath
            {
                & (Get-Module DevPilot.NamedAreEqualBridge) {
                    param($InputEntry, $InputHead)
                    Get-NamedBridgeRelevantChangeSet `
                        -ChangeSet ([ordered]@{
                            changedFiles = 1
                            changedLines = 0
                            entries = @($InputEntry)
                        }) `
                        -Head $InputHead
                } $unsafe (New-TestHead)
            } | Should -Throw
        }
        $bridgeEntry = $entry |
            ConvertTo-Json -Depth 16 |
            ConvertFrom-Json -AsHashtable `
                -Depth 16
        $bridgeEntry.path = '../../escape.cs'
        $bridgeResult = Invoke-TestBridge `
            -Entry $bridgeEntry `
            -Name unsafe-path
        $bridgeResult.state |
            Should -BeExactly 'partial'
        $bridgeResult.records |
            Should -HaveCount 0

        $unsafeRename = $entry |
            ConvertTo-Json -Depth 16 |
            ConvertFrom-Json -AsHashtable `
                -Depth 16
        $unsafeRename.path = 'tests/Renamed.cs'
        $unsafeRename.changeType = 'rename'
        $unsafeRename.oldPath = '../Old.cs'
        $unsafeRename.derivation.classification =
            'derivation-unknown'
        $unsafeRename.derivation.state = 'unknown'
        $unsafeRename.derivation.changeType =
            'renamed'
        $unsafeRename.derivation.pathRelation =
            'renamed'
        {
            & (Get-Module DevPilot.NamedAreEqualBridge) {
                param($InputEntry, $InputHead)
                Get-NamedBridgeChangeDisposition `
                    -Entry $InputEntry `
                    -Head $InputHead
            } $unsafeRename (New-TestHead)
        } | Should -Throw
    }

    It 'refuses same-length content mutation and false-typed counts' {
        $claimed = 'class A {}'
        $actual = 'class B {}'
        $claimedDigest =
            Get-TestTextDigest $claimed
        $entry = [ordered]@{
            path = 'tests/Mutated.cs'
            changeType = 'edit'
            state = 'complete'
            spans = @()
            content = $actual
            byteLength =
                [Text.Encoding]::UTF8.
                    GetByteCount($actual)
            sourceDigest = $claimedDigest
            derivation = [ordered]@{
                schemaVersion = 1
                kind =
                    'devpilot-current-line-derivation-v1'
                producer = 'active-pr-intake-v1'
                state = 'complete'
                classification =
                    'identical-content'
                changeType = 'modified'
                pathRelation = 'same-path'
                sourceCommit = 'c' * 40
                targetCommit = 'd' * 40
                sourceContentState = 'available'
                targetContentState = 'available'
                sourceContentSha256 =
                    $claimedDigest
                targetContentSha256 =
                    $claimedDigest
                sourceByteLength =
                    [Text.Encoding]::UTF8.
                        GetByteCount($claimed)
                targetByteLength =
                    [Text.Encoding]::UTF8.
                        GetByteCount($claimed)
                spanCount = 0
                currentLineCount = 0
            }
        }
        $mutated = Invoke-TestBridge `
            -Entry $entry -Name mutated
        $mutated.state | Should -BeExactly 'partial'
        $mutated.records | Should -HaveCount 0

        foreach ($mutation in @(
                {
                    param($value)
                    $value.byteLength = '10'
                },
                {
                    param($value)
                    $value.byteLength = [decimal]10.1
                },
                {
                    param($value)
                    $value.derivation.schemaVersion =
                        [decimal]1.1
                },
                {
                    param($value)
                    $value.derivation.sourceByteLength =
                        [decimal]10.1
                },
                {
                    param($value)
                    $value.derivation.spanCount =
                        [decimal]0.1
                })) {
            $invalid = $entry |
                ConvertTo-Json -Depth 16 |
                ConvertFrom-Json -AsHashtable `
                    -Depth 16
            & $mutation $invalid
            $result = Invoke-TestBridge `
                -Entry $invalid `
                -Name (
                    'typed-' +
                    [guid]::NewGuid().ToString('N'))
            $result.state |
                Should -BeExactly 'partial'
            $result.records | Should -HaveCount 0
        }
    }

    It 'refuses malformed Named baseline inventory counts and span totals' {
        $content = 'class Counts {}'
        $entry = [ordered]@{
            path = 'tests/Counts.cs'
            changeType = 'edit'
            state = 'complete'
            spans = @([ordered]@{
                    startLine = 1
                    endLine = 1
                    state = 'complete'
                    sourceDigest =
                        Get-TestTextDigest 'span'
                })
            content = $content
            byteLength =
                [Text.Encoding]::UTF8.
                    GetByteCount($content)
            sourceDigest =
                Get-TestTextDigest $content
            derivation = [ordered]@{
                schemaVersion = 1
                kind =
                    'devpilot-current-line-derivation-v1'
                producer = 'active-pr-intake-v1'
                state = 'complete'
                classification = 'current-lines'
                changeType = 'modified'
                pathRelation = 'same-path'
                sourceCommit = 'c' * 40
                targetCommit = 'd' * 40
                sourceContentState = 'available'
                targetContentState = 'available'
                sourceContentSha256 =
                    Get-TestTextDigest $content
                targetContentSha256 =
                    Get-TestTextDigest 'target'
                sourceByteLength =
                    [Text.Encoding]::UTF8.
                        GetByteCount($content)
                targetByteLength = 6
                spanCount = 1
                currentLineCount = 1
            }
        }
        $head = New-TestHead
        foreach ($changes in @(
                [ordered]@{
                    changedFiles = 2
                    changedLines = 1
                    entries = @($entry)
                },
                [ordered]@{
                    changedFiles = 0
                    changedLines = 1
                    entries = @()
                },
                [ordered]@{
                    changedFiles = [decimal]1.1
                    changedLines = 1
                    entries = @($entry)
                },
                [ordered]@{
                    changedFiles = 1
                    changedLines = 2
                    entries = @($entry)
                })) {
            {
                & (Get-Module `
                    DevPilot.NamedAreEqualBridge) {
                    param($InputChanges, $InputHead)
                    Get-NamedBridgeRelevantChangeSet `
                        -ChangeSet $InputChanges `
                        -Head $InputHead
                } $changes $head
            } | Should -Throw
        }
    }

    It 'refuses contradictory deleted metadata' {
        $entry = [ordered]@{
            path = 'tests/Deleted.cs'
            changeType = 'delete'
            state = 'complete'
            spans = @()
            content = 'still current'
            byteLength = 13
            sourceDigest =
                Get-TestTextDigest 'still current'
            derivation = [ordered]@{
                schemaVersion = 1
                kind =
                    'devpilot-current-line-derivation-v1'
                producer = 'active-pr-intake-v1'
                state = 'complete'
                classification = 'deletion-only'
                changeType = 'deleted'
                pathRelation = 'same-path'
                sourceCommit = 'c' * 40
                targetCommit = 'd' * 40
                sourceContentState =
                    'absent-deleted'
                targetContentState =
                    'not-read-deleted'
                sourceContentSha256 =
                    Get-TestTextDigest ''
                targetContentSha256 = 'unknown'
                sourceByteLength = 0
                targetByteLength = 0
                spanCount = 0
                currentLineCount = 0
            }
        }
        $result = Invoke-TestBridge `
            -Entry $entry -Name deleted-conflict
        $result.state | Should -BeExactly 'partial'
        $result.records | Should -HaveCount 0
    }

    It 'keeps explicit unknown derivation UNKNOWN even with valid positive spans' {
        $content = @'
using Microsoft.VisualStudio.TestTools.UnitTesting;
[TestClass]
class Checks {
    [TestMethod]
    void Verify() {
        Assert.AreEqual(1, items.Count);
    }
}
'@
        $entry = [ordered]@{
            path = 'tests/UnknownProof.cs'
            changeType = 'edit'
            state = 'complete'
            spans = @([ordered]@{
                    startLine = 6
                    endLine = 6
                    state = 'complete'
                    sourceDigest =
                        Get-TestTextDigest 'span'
                })
            content = $content
            byteLength =
                [Text.Encoding]::UTF8.
                    GetByteCount($content)
            sourceDigest =
                Get-TestTextDigest $content
            derivation = [ordered]@{
                schemaVersion = 1
                kind =
                    'devpilot-current-line-derivation-v1'
                producer = 'active-pr-intake-v1'
                state = 'complete'
                classification =
                    'derivation-unknown'
                changeType = 'modified'
                pathRelation = 'same-path'
                sourceCommit = 'c' * 40
                targetCommit = 'd' * 40
                sourceContentState = 'available'
                targetContentState = 'available'
                sourceContentSha256 =
                    Get-TestTextDigest $content
                targetContentSha256 =
                    Get-TestTextDigest 'target'
                sourceByteLength =
                    [Text.Encoding]::UTF8.
                        GetByteCount($content)
                targetByteLength = 6
                spanCount = 1
                currentLineCount = 1
            }
        }
        $result = Invoke-TestBridge `
            -Entry $entry -Name explicit-unknown
        $result.state | Should -BeExactly 'partial'
        $result.records | Should -HaveCount 1
        $result.records[0].state |
            Should -BeExactly 'unknown'
    }

    It 'keeps an empty added CSharp file on the current-lines path' {
        $emptyDigest = Get-TestTextDigest ''
        $entry = [ordered]@{
            path = 'tests/Empty.cs'
            changeType = 'add'
            state = 'complete'
            spans = @([ordered]@{
                    startLine = 1
                    endLine = 1
                    state = 'complete'
                    sourceDigest =
                        Get-TestTextDigest 'span'
                })
            content = ''
            byteLength = 0
            sourceDigest = $emptyDigest
            derivation = [ordered]@{
                schemaVersion = 1
                kind =
                    'devpilot-current-line-derivation-v1'
                producer = 'active-pr-intake-v1'
                state = 'complete'
                classification = 'current-lines'
                changeType = 'added'
                pathRelation = 'same-path'
                sourceCommit = 'c' * 40
                targetCommit = 'd' * 40
                sourceContentState = 'available'
                targetContentState = 'available'
                sourceContentSha256 = $emptyDigest
                targetContentSha256 = $emptyDigest
                sourceByteLength = 0
                targetByteLength = 0
                spanCount = 1
                currentLineCount = 1
            }
        }
        $result = Invoke-TestBridge `
            -Entry $entry -Name empty-added
        $result.state | Should -BeExactly 'completed'
        $result.records[0].state |
            Should -BeExactly 'completed'
    }

    It 'keeps rename and unknown CSharp evidence UNKNOWN' {
        $content = 'class Rename {}'
        $rename = [ordered]@{
            path = 'tests/Rename.cs'
            oldPath = 'tests/OldRename.cs'
            changeType = 'rename'
            state = 'complete'
            spans = @()
            content = $content
            byteLength =
                [Text.Encoding]::UTF8.GetByteCount(
                    $content)
            sourceDigest =
                Get-TestTextDigest $content
            derivation = [ordered]@{
                schemaVersion = 1
                kind =
                    'devpilot-current-line-derivation-v1'
                producer = 'active-pr-intake-v1'
                state = 'complete'
                classification =
                    'derivation-unknown'
                changeType = 'renamed'
                pathRelation = 'renamed'
                sourceCommit = 'c' * 40
                targetCommit = 'd' * 40
                sourceContentState = 'available'
                targetContentState = 'available'
                sourceContentSha256 =
                    Get-TestTextDigest $content
                targetContentSha256 =
                    Get-TestTextDigest $content
                sourceByteLength =
                    [Text.Encoding]::UTF8.
                        GetByteCount($content)
                targetByteLength =
                    [Text.Encoding]::UTF8.
                        GetByteCount($content)
                spanCount = 0
                currentLineCount = 0
            }
        }
        $renameResult = Invoke-TestBridge `
            -Entry $rename -Name rename
        $renameResult.state | Should -BeExactly 'partial'
        $renameResult.records | Should -HaveCount 1 `
            -Because ($renameResult |
                ConvertTo-Json -Depth 20 -Compress)
        $renameResult.records[0].state |
            Should -BeExactly 'unknown'

        $unknown = $rename |
            ConvertTo-Json -Depth 16 |
            ConvertFrom-Json -AsHashtable `
                -Depth 16
        $unknown.Remove('oldPath')
        $unknown.changeType = 'edit'
        $unknown.state = 'unknown'
        $unknown.content = $null
        $unknown.byteLength = 0
        $unknown.derivation.state = 'unknown'
        $unknown.derivation.changeType = 'modified'
        $unknown.derivation.pathRelation = 'same-path'
        $unknown.derivation.sourceContentState =
            'unavailable'
        $unknown.derivation.targetContentState =
            'unavailable'
        $unknown.derivation.sourceContentSha256 =
            'unknown'
        $unknown.derivation.targetContentSha256 =
            'unknown'
        $unknown.derivation.sourceByteLength = 0
        $unknown.derivation.targetByteLength = 0
        $unknownResult = Invoke-TestBridge `
            -Entry $unknown -Name unknown
        $unknownResult.state | Should -BeExactly 'partial'
        $unknownResult.records[0].state |
            Should -BeExactly 'unknown'
    }
}
