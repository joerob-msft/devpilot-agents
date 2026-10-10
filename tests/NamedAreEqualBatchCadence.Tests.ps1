#requires -Version 7.0

BeforeAll {
    $repo = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $repo `
            'src\DevPilot.ActivePrIntake\DevPilot.ActivePrIntake.psd1') `
        -Force
    Import-Module (Join-Path $repo `
            'src\DevPilot.NamedAreEqualBridge\DevPilot.NamedAreEqualBridge.psd1') `
        -Force
    Import-Module (Join-Path $repo `
            'src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1') `
        -Force
    Import-Module (Join-Path $repo `
            'src\DevPilot.OwnerAdapters\DevPilot.OwnerAdapters.psd1') `
        -Force
    Import-Module (Join-Path $repo `
            'src\DevPilot.OwnerCapability\DevPilot.OwnerCapability.psd1') `
        -Force
    . (Join-Path $repo `
        'src\Agents\reviewer\ApprovedOwnerV2Comments.ps1')
    . (Join-Path $repo `
        'src\Agents\reviewer\AutomaticOwnerV2Comments.ps1')

    function New-BatchIntakeConfig {
        $config = Get-Content (Join-Path $repo `
                'samples\active-pr-intake.config.json') -Raw |
            ConvertFrom-Json -AsHashtable -Depth 32
        $config.enabled = $true
        $config.limits.pageSize = 10
        $config.limits.maxHeadsPerRun = 1
        $config.limits.maxReads = 256
        $config.limits.maxSeconds = 60
        $config.toolkit = [ordered]@{
            ref = 'refs/heads/current'
            head = 'a' * 40
            tree = 'b' * 40
        }
        return $config
    }

    function New-BatchIntakeProvider {
        param(
            [Parameter(Mandatory)]
            [Collections.IDictionary]$Config
        )
        $rows = @(1..8 | ForEach-Object {
                [ordered]@{
                    pullRequestId = $_
                    status = 'active'
                    isDraft = $false
                    targetRef = 'refs/heads/master'
                }
            })
        return {
            param($Operation, $Request)
            switch ($Operation) {
                Identity {
                    return [ordered]@{} +
                        $Config.expectedAccount
                }
                ListPage {
                    $items = @($rows |
                        Select-Object -Skip ([int]$Request.skip) `
                            -First ([int]$Request.top))
                    return @{
                        items = $items
                        count = $items.Count
                        totalCount = $rows.Count
                    }
                }
                Head {
                    $id = [int]$Request.pullRequestId
                    return @{
                        pullRequestId = $id
                        repositoryId = $Config.repositoryId
                        projectId = $Config.projectId
                        sourceRef = "refs/heads/feature-$id"
                        targetRef = 'refs/heads/master'
                        sourceCommit =
                            ('{0:x40}' -f $id)
                        targetCommit = 'f' * 40
                        iterationId = 1
                        status = 'active'
                        isDraft = $false
                    }
                }
                Changes {
                    return @{
                        changedFiles = 0
                        changedLines = 0
                    }
                }
                Discussions {
                    return @{
                        threads = @()
                        count = 0
                    }
                }
                default {
                    throw "unexpected:$Operation"
                }
            }
        }.GetNewClosure()
    }

    function Get-BridgeTextDigest {
        param([string]$Value)
        return 'v1:sha256:' +
            [Convert]::ToHexString(
                [Security.Cryptography.SHA256]::HashData(
                    [Text.Encoding]::UTF8.GetBytes($Value))).
                ToLowerInvariant()
    }

    function Add-BatchChangeDerivations {
        param(
            [Parameter(Mandatory)]
            [Collections.IDictionary]$ChangeSet,
            [Parameter(Mandatory)]
            [Collections.IDictionary]$Head
        )
        $copy = $ChangeSet |
            ConvertTo-Json -Depth 32 |
            ConvertFrom-Json -AsHashtable `
                -Depth 32
        foreach ($entry in @($copy.entries)) {
            if ($entry -isnot
                    [Collections.IDictionary] -or
                [string]::IsNullOrWhiteSpace(
                    [string]$entry.path) -or
                [IO.Path]::GetExtension(
                    [string]$entry.path) -ine '.cs') {
                continue
            }
            if (-not $entry.Contains('changeType')) {
                $entry.changeType = 'edit'
            }
            if ([string]$entry.state -ceq
                'complete') {
                $fixtureContent = 'fixture'
                $fixtureBytes =
                    [Text.Encoding]::UTF8.GetByteCount(
                        $fixtureContent)
                $fixtureDigest =
                    Get-BridgeTextDigest $fixtureContent
                $entry.content = $fixtureContent
                $entry.byteLength = $fixtureBytes
                $entry.sourceDigest = $fixtureDigest
            }
            else {
                $entry.content = $null
                $entry.byteLength = 0
                if (-not $entry.Contains(
                        'sourceDigest')) {
                    $entry.sourceDigest =
                        Get-BridgeTextDigest (
                            'unknown-fixture')
                }
            }
            $validLineCount = 0L
            $validSpans = $true
            foreach ($span in @($entry.spans)) {
                [long]$start = 0
                [long]$end = 0
                if ($span -isnot
                        [Collections.IDictionary] -or
                    -not [long]::TryParse(
                        [string]$span.startLine,
                        [ref]$start) -or
                    -not [long]::TryParse(
                        [string]$span.endLine,
                        [ref]$end) -or
                    $start -lt 1 -or
                    $end -lt $start -or
                    $end -gt [int]::MaxValue) {
                    $validSpans = $false
                    continue
                }
                $validLineCount +=
                    $end - $start + 1
            }
            $classification = if (
                [string]$entry.state -ceq
                    'complete' -and
                $validSpans -and
                @($entry.spans).Count -gt 0
            ) {
                'current-lines'
            }
            else {
                'derivation-unknown'
            }
            $entry.derivation = [ordered]@{
                schemaVersion = 1
                kind =
                    'devpilot-current-line-derivation-v1'
                producer = 'active-pr-intake-v1'
                state = $(if (
                    [string]$entry.state -ceq
                        'complete'
                ) { 'complete' } else { 'unknown' })
                classification = $classification
                changeType = 'modified'
                pathRelation = 'same-path'
                sourceCommit =
                    [string]$Head.sourceCommit
                targetCommit =
                    [string]$Head.targetCommit
                sourceContentState = $(if (
                    [string]$entry.state -ceq
                        'complete'
                ) { 'available' } else { 'unavailable' })
                targetContentState = 'unavailable'
                sourceContentSha256 = 'unknown'
                targetContentSha256 = 'unknown'
                sourceByteLength = 0
                targetByteLength = 0
                spanCount = @($entry.spans).Count
                currentLineCount = $validLineCount
            }
            if ($classification -ceq
                'current-lines') {
                $entry.derivation.
                    sourceContentSha256 =
                    [string]$entry.sourceDigest
                $entry.derivation.
                    sourceByteLength =
                    [long]$entry.byteLength
            }
        }
        return $copy
    }

    function Get-BatchRelevantChangeSet {
        param(
            [Parameter(Mandatory)]
            [Collections.IDictionary]$ChangeSet
        )
        $head = [ordered]@{
            sourceCommit = 'a' * 40
            targetCommit = 'f' * 40
        }
        if (-not $ChangeSet.Contains(
                'changedFiles') -or
            $ChangeSet.changedFiles -isnot [int] -and
            $ChangeSet.changedFiles -isnot [long] -or
            -not $ChangeSet.Contains(
                'changedLines') -or
            $ChangeSet.changedLines -isnot [int] -and
            $ChangeSet.changedLines -isnot [long] -or
            $ChangeSet.entries -isnot [array] -or
            [long]$ChangeSet.changedFiles -ne
                @($ChangeSet.entries).Count -or
            [long]$ChangeSet.changedFiles -lt 0 -or
            [long]$ChangeSet.changedLines -lt 0 -or
            ([long]$ChangeSet.changedFiles -eq 0 -and
                [long]$ChangeSet.changedLines -ne 0)) {
            return & (
                Get-Module DevPilot.NamedAreEqualBridge) {
                param($InputChangeSet, $InputHead)
                Get-NamedBridgeRelevantChangeSet `
                    -ChangeSet $InputChangeSet `
                    -Head $InputHead
            } $ChangeSet $head
        }
        $prepared =
            Add-BatchChangeDerivations `
                -ChangeSet $ChangeSet -Head $head
        return & (
            Get-Module DevPilot.NamedAreEqualBridge) {
            param($InputChangeSet, $InputHead)
            Get-NamedBridgeRelevantChangeSet `
                -ChangeSet $InputChangeSet `
                -Head $InputHead
        } $prepared $head
    }

    function New-BatchBridgeProvider {
        param(
            [Parameter(Mandatory)]
            [Collections.IDictionary]$Config,
            [int]$PostHeadFailureId = 0
        )
        $rows = @(1..4 | ForEach-Object {
                [ordered]@{
                    pullRequestId = $_
                    status = 'active'
                    isDraft = $false
                    targetRef = 'refs/heads/master'
                }
            })
        $digestCommand = Get-Command Get-BridgeTextDigest `
            -CommandType Function
        $calls = [Collections.Generic.List[string]]::new()
        $headVisits = @{}
        $handler = {
            param($Operation, $Request)
            [void]$calls.Add(
                "$Operation`:$($Request.pullRequestId)")
            switch ($Operation) {
                Identity {
                    return [ordered]@{} +
                        $Config.expectedAccount
                }
                ListPage {
                    $items = @($rows |
                        Select-Object -Skip ([int]$Request.skip) `
                            -First ([int]$Request.top))
                    return @{
                        items = $items
                        count = $items.Count
                        totalCount = $rows.Count
                    }
                }
                Head {
                    $id = [int]$Request.pullRequestId
                    if (-not $headVisits.ContainsKey($id)) {
                        $headVisits[$id] = 0
                    }
                    $headVisits[$id]++
                    if ($PostHeadFailureId -eq $id -and
                        $headVisits[$id] -ge 3) {
                        throw 'head-inconsistent'
                    }
                    return @{
                        pullRequestId = $id
                        repositoryId = $Config.repositoryId
                        projectId = $Config.projectId
                        sourceRef = "refs/heads/feature-$id"
                        targetRef = 'refs/heads/master'
                        sourceCommit = ('{0:x40}' -f $id)
                        targetCommit = 'f' * 40
                        iterationId = 1
                        status = 'active'
                        isDraft = $false
                    }
                }
                Changes {
                    $id = [int]$Request.pullRequestId
                    $callLines = if ($id -eq 4) {
                        @(1..100 | ForEach-Object {
                                "        Assert.AreEqual($_, actual);"
                            })
                    }
                    else {
                        @()
                    }
                    $content = @(
                        'using Microsoft.VisualStudio.TestTools.UnitTesting;',
                        '[TestClass]',
                        "class Checks$id {",
                        '    [TestMethod]',
                        "    void Verify$id() {",
                        '        var actual = 1;'
                    ) + $callLines + @(
                        '    }',
                        '}'
                    )
                    $text = $content -join "`n"
                    return @{
                        changedFiles = 1
                        changedLines = $content.Count
                        entries = @([ordered]@{
                                changeTrackingId = $id
                                path = "tests/Checks$id.cs"
                                changeType = 'edit'
                                state = 'complete'
                                spans = @([ordered]@{
                                        startLine = 1
                                        endLine = $content.Count
                                        state = 'complete'
                                        sourceDigest =
                                            & $digestCommand $text
                                    })
                                content = $text
                                byteLength =
                                    [Text.Encoding]::UTF8.
                                        GetByteCount($text)
                                sourceDigest =
                                    & $digestCommand $text
                                derivation = [ordered]@{
                                    schemaVersion = 1
                                    kind =
                                        'devpilot-current-line-derivation-v1'
                                    producer =
                                        'active-pr-intake-v1'
                                    state = 'complete'
                                    classification =
                                        'current-lines'
                                    changeType = 'modified'
                                    pathRelation =
                                        'same-path'
                                    sourceCommit =
                                        ('{0:x40}' -f $id)
                                    targetCommit = 'f' * 40
                                    sourceContentState =
                                        'available'
                                    targetContentState =
                                        'available'
                                    sourceContentSha256 =
                                        & $digestCommand $text
                                    targetContentSha256 =
                                        & $digestCommand 'target'
                                    sourceByteLength =
                                        [Text.Encoding]::UTF8.
                                            GetByteCount($text)
                                    targetByteLength = 6
                                    spanCount = 1
                                    currentLineCount =
                                        $content.Count
                                }
                            })
                    }
                }
                Discussions {
                    return @{
                        threads = @()
                        count = 0
                    }
                }
                default {
                    throw "unexpected:$Operation"
                }
            }
        }.GetNewClosure()
        return [pscustomobject]@{
            Handler = $handler
            Calls = $calls
        }
    }
}

Describe 'Named batch cadence' {
    It 'routes only current CSharp files to the Named evaluator' {
        $changeSet = [ordered]@{
            changedFiles = 3
            changedLines = 4
            entries = @(
                [ordered]@{
                    path = 'src/Checks.cs'
                    state = 'complete'
                    spans = @([ordered]@{
                            startLine = 4
                            endLine = 6
                        })
                },
                [ordered]@{
                    path = 'settings/app.yaml'
                    state = 'unknown'
                    spans = @()
                },
                [ordered]@{
                    path = 'src/Unknown.cs'
                    state = 'unknown'
                    spans = @([ordered]@{
                            startLine = 9
                            endLine = 9
                        })
                })
        }
        $filtered = Get-BatchRelevantChangeSet `
            -ChangeSet $changeSet

        $filtered.changedFiles | Should -Be 2
        $filtered.changedLines | Should -Be 3
        @($filtered.entries.path) |
            Should -Be @(
                'src/Checks.cs',
                'src/Unknown.cs')
        @($filtered.entries | Where-Object {
                [string]$_.state -ceq 'unknown'
            }) | Should -HaveCount 1

        $irrelevant = Get-BatchRelevantChangeSet `
            -ChangeSet ([ordered]@{
                changedFiles = 1
                changedLines = 0
                entries = @([ordered]@{
                        path = 'settings/app.yaml'
                        state = 'unknown'
                        spans = @()
                    })
            })
        $irrelevant.changedFiles | Should -Be 0
        @($irrelevant.entries) | Should -HaveCount 0

        foreach ($invalidSpanSet in @(
                [ordered]@{
                    changedFiles = 1
                    changedLines = 1
                    entries = @([ordered]@{
                            path = 'tests/InvalidSpan.cs'
                            state = 'unknown'
                            spans = @([ordered]@{
                                    startLine = 0
                                    endLine = 0
                                })
                        })
                },
                [ordered]@{
                    changedFiles = 1
                    changedLines = 1
                    entries = @([ordered]@{
                            path =
                                'tests/NonnumericSpan.cs'
                            state = 'unknown'
                            spans = @([ordered]@{
                                    startLine = 'bad'
                                    endLine = 'worse'
                                })
                        })
                },
                [ordered]@{
                    changedFiles = 1
                    changedLines = 2
                    entries = @([ordered]@{
                            path =
                                'tests/OversizedSpans.cs'
                            state = 'unknown'
                            spans = @(
                                [ordered]@{
                                    startLine = 1
                                    endLine =
                                        [long]::MaxValue
                                },
                                [ordered]@{
                                    startLine = 1
                                    endLine =
                                        [long]::MaxValue
                                })
                        })
                })) {
            {
                Get-BatchRelevantChangeSet `
                    -ChangeSet $invalidSpanSet
            } | Should -Throw
        }

        {
            Get-BatchRelevantChangeSet `
                -ChangeSet ([ordered]@{
                    changedFiles = 2
                    changedLines = 1
                    entries = @([ordered]@{
                            path = 'tests/OnlyOne.cs'
                            state = 'complete'
                            spans = @()
                        })
                })
        } | Should -Throw

        foreach ($invalidCount in @(
                $null,
                [decimal]0.4)) {
            {
                Get-BatchRelevantChangeSet `
                    -ChangeSet ([ordered]@{
                        changedFiles = $invalidCount
                        changedLines = 0
                        entries = [object[]]@()
                    })
            } | Should -Throw
        }

        foreach ($invalidChangeSet in @(
                [ordered]@{
                    changedFiles = -1
                    changedLines = 0
                    entries = [object[]]@()
                },
                [ordered]@{
                    changedFiles = 0
                    changedLines = -1
                    entries = [object[]]@()
                },
                [ordered]@{
                    changedFiles = 0
                    changedLines = 1
                    entries = [object[]]@()
                },
                [ordered]@{
                    changedFiles = 1
                    changedLines = 0
                    entries = @([ordered]@{
                            path = ''
                            state = 'unknown'
                            spans = @()
                        })
                },
                [ordered]@{
                    changedFiles = 1
                    changedLines = 0
                    entries = @([ordered]@{
                            path = $null
                            state = 'unknown'
                            spans = @()
                        })
                })) {
            {
                Get-BatchRelevantChangeSet `
                    -ChangeSet $invalidChangeSet
            } | Should -Throw
        }

        $diagnostic = & (
            Get-Module DevPilot.NamedAreEqualBridge) {
            try {
                throw (
                    'File evidence for ordinal ' +
                    ('9' * 64) +
                    ' was incomplete or unknown.')
            }
            catch {
                Get-NamedBridgeFailureDiagnostic `
                    -ErrorRecord $_ `
                    -Operation package-preflight
            }
        }
        $diagnostic.category |
            Should -BeExactly 'file-evidence-incomplete'
        $diagnostic.fileOrdinal |
            Should -BeNullOrEmpty
        $diagnostic.messageSha256 |
            Should -Match '^[0-9a-f]{64}$'
    }

    It 'advances four picks from the existing cursor without changing config digest' {
        $config = New-BatchIntakeConfig
        $provider = New-BatchIntakeProvider -Config $config
        $state = Join-Path $TestDrive 'cursor-state'

        $first = Invoke-ActivePrIntake `
            -Config $config -Provider $provider `
            -StateRoot $state -RepositoryRoot $repo `
            -MaximumHeadsThisRun 1 -Run
        {
            Invoke-ActivePrIntake `
                -Config $config -Provider $provider `
                -StateRoot $state -RepositoryRoot $repo `
                -MaximumHeadsThisRun 4 `
                -MaximumSecondsThisRun 721 -Run
        } | Should -Throw
        $second = Invoke-ActivePrIntake `
            -Config $config -Provider $provider `
            -StateRoot $state -RepositoryRoot $repo `
            -MaximumHeadsThisRun 4 `
            -MaximumSecondsThisRun 720 -Run

        $first.binding.configDigest |
            Should -BeExactly $second.binding.configDigest
        $first.execution.maximumHeadsThisRun | Should -Be 1
        $second.execution.maximumHeadsThisRun | Should -Be 4
        $second.execution.maximumSecondsThisRun |
            Should -Be 720
        @($first.heads | Where-Object {
                [string]$_.reasonCode -ceq 'rules-incomplete'
            }).pullRequestId |
            Should -Be @(1)
        @($second.heads | Where-Object {
                [string]$_.reasonCode -ceq 'rules-incomplete'
            }).pullRequestId |
            Should -Be @(2, 3, 4, 5)
        $first.cursor.nextPullRequestId | Should -Be 2
        $second.cursor.nextPullRequestId | Should -Be 6

        $revised = $config | ConvertTo-Json -Depth 32 |
            ConvertFrom-Json -AsHashtable -Depth 32
        $revised.toolkit.head = 'c' * 40
        $revised.toolkit.tree = 'd' * 40
        $revised.cursorCompatibility = [ordered]@{
            previousConfigDigest =
                [string]$second.binding.configDigest
            previousToolkitHead = 'a' * 40
            previousToolkitTree = 'b' * 40
        }
        $revisedProvider =
            New-BatchIntakeProvider -Config $revised
        $failedProvider = {
            param($Operation, $Request)
            if ($Operation -ceq 'ListPage') {
                throw 'read-inaccessible'
            }
            return & $revisedProvider $Operation $Request
        }.GetNewClosure()
        $failedTransition = Invoke-ActivePrIntake `
            -Config $revised -Provider $failedProvider `
            -StateRoot $state -RepositoryRoot $repo `
            -MaximumHeadsThisRun 4 -Run
        $failedTransition.state |
            Should -BeExactly 'unknown'
        $failedTransition.binding.cursorTransitionApplied |
            Should -BeTrue
        $failedTransition.cursor.nextPullRequestId |
            Should -Be 6
        $third = Invoke-ActivePrIntake `
            -Config $revised -Provider $revisedProvider `
            -StateRoot $state -RepositoryRoot $repo `
            -MaximumHeadsThisRun 4 -Run

        $third.binding.configDigest |
            Should -Not -BeExactly $second.binding.configDigest
        $third.binding.cursorTransitionApplied |
            Should -BeFalse
        $third.binding.cursorSourceConfigDigest |
            Should -BeExactly (
                [string]$failedTransition.binding.configDigest)
        @($third.heads | Where-Object {
                [string]$_.reasonCode -ceq 'rules-incomplete'
            }).pullRequestId |
            Should -Be @(1, 6, 7, 8)
        $third.cursor.nextPullRequestId | Should -Be 2
    }

    It 'enforces one shared create budget of two across four identities' {
        $script:requested = [Collections.Generic.List[int]]::new()
        Mock Assert-AutomaticOwnerV2ServicePolicy {}
        Mock Invoke-AutomaticOwnerV2Comments {
            param(
                $Evidence,
                $Policy,
                $DeliveryRoot,
                $Key,
                $Provider,
                $MaximumCreates
            )
            [void]$script:requested.Add([int]$MaximumCreates)
            return [pscustomobject]@{
                health = 'healthy'
                providerWrites = $(if (
                        $MaximumCreates -gt 0
                    ) { 1 } else { 0 })
                modelWrites = 0
                remainingWouldCreate = 0
                events = @()
            }
        }
        $evidence = @(1..4 | ForEach-Object {
                [pscustomobject]@{
                    Identity = ('{0:x64}' -f $_)
                    Observation = @{
                        findings = @(@{
                                reconciliation = @{
                                    classification =
                                        'wouldCreate'
                                }
                            })
                    }
                }
            })
        $result = Invoke-AutomaticNamedAreEqualBatch `
            -Evidence $evidence -Policy @{
                limits = @{ maxCreatesPerRun = 2 }
            } `
            -DeliveryRoot $TestDrive -Key ([byte[]](1..32)) `
            -Provider { throw 'not invoked' } -MaximumCreates 2

        $result.providerWrites | Should -Be 2
        $result.remainingCreates | Should -Be 0
        $result.health | Should -BeExactly 'partial'
        @($result.results) | Should -HaveCount 2
        @($result.deferred) | Should -HaveCount 2
        $script:requested.ToArray() | Should -Be @(2, 1)
    }

    It 'honors a signed run ceiling of one across two identities' {
        $script:requested = [Collections.Generic.List[int]]::new()
        Mock Assert-AutomaticOwnerV2ServicePolicy {}
        Mock Invoke-AutomaticOwnerV2Comments {
            param(
                $Evidence,
                $Policy,
                $DeliveryRoot,
                $Key,
                $Provider,
                $MaximumCreates
            )
            [void]$script:requested.Add([int]$MaximumCreates)
            return [pscustomobject]@{
                health = 'healthy'
                providerWrites = 1
                modelWrites = 0
                remainingWouldCreate = 0
                events = @()
            }
        }
        $evidence = @(1..2 | ForEach-Object {
                [pscustomobject]@{
                    Identity = ('{0:x64}' -f $_)
                    Observation = @{
                        findings = @(@{
                                reconciliation = @{
                                    classification =
                                        'wouldCreate'
                                }
                            })
                    }
                }
            })
        $result = Invoke-AutomaticNamedAreEqualBatch `
            -Evidence $evidence -Policy @{
                limits = @{ maxCreatesPerRun = 1 }
            } `
            -DeliveryRoot $TestDrive `
            -Key ([byte[]](1..32)) `
            -Provider { throw 'not invoked' } `
            -MaximumCreates 2

        $result.providerWrites | Should -Be 1
        $result.remainingCreates | Should -Be 0
        @($result.results) | Should -HaveCount 1
        @($result.deferred) | Should -HaveCount 1
        $script:requested.ToArray() | Should -Be @(1)
    }

    It 'retains completed heads when one of four selected acquisitions is missing' {
        $config = New-BatchIntakeConfig
        $config.namedRule = [ordered]@{
            repositoryId = 'devpilot-agents'
            path =
                'src/DevPilot.OwnerCapability/Policy/named-areequal-arguments.v1.txt'
            section = 'bpm-named-areequal-arguments@1'
            hash =
                'v1:sha256:8b9fa35bd2bc96e9f0dbfc878806b540603ab4f255ddf41bf120311913b831f4'
            length = 653
        }
        $config.rules = @([ordered]@{
                id = 'bpm-named-areequal-arguments@1'
                capability =
                    'bpm-named-areequal-arguments@1'
            })
        $config.toolkit = [ordered]@{
            ref = 'refs/heads/batch-test'
            head = 'a' * 40
            tree = 'b' * 40
        }
        $config.capability = [ordered]@{
            id = 'bpm-named-areequal-arguments@1'
            implementationSha256 =
                '7ed3583591b43dbb351292ea9a37a53fc32fc9f0fd3403c821e3209310598e3a'
        }
        $reviewer = New-OwnerAzureDevOpsReviewerIdentity `
            -Id $config.expectedAccount.id `
            -Descriptor $config.expectedAccount.descriptor `
            -UniqueName $config.expectedAccount.uniqueName
        $adapter = New-OwnerAzureDevOpsReadOnlyProviderAdapter `
            -Name batch-test -ReviewerIdentity $reviewer `
            -Handler { throw 'not invoked' }
        $config.subjectProvider = [ordered]@{
            kind = 'azure-devops-read-only-v1'
            organization = $config.organization
            projectName = $config.projectName
            projectId = $config.projectId
            repositoryName = 'ExampleRepository'
            repositoryId = $config.repositoryId
            maximumFiles = 64
            maximumBytes = 16777216
            maximumReads = 128
        }
        $config.discussionProvider = [ordered]@{
            kind = 'azure-devops-rest-owner-discussions-v1'
            mappingDigest =
                $adapter.AzureDevOpsDiscussionMappingDigest
            reviewerIdentity = [ordered]@{
                id = [string]$reviewer.Id
                descriptor = [string]$reviewer.Descriptor
                uniqueName = [string]$reviewer.UniqueName
                digest =
                    $adapter.AzureDevOpsReviewerIdentityDigest
            }
        }
        $config.autoCreateNamedAreEqualComments = $false
        $config.limits.maxChangedFiles = 64
        $config.limits.maxChangedLines = 5000
        $provider = New-BatchBridgeProvider `
            -Config $config -PostHeadFailureId 3
        $state = Join-Path $TestDrive 'bridge-batch-state'
        $manifest = Join-Path $TestDrive 'bridge-batch-manifest.json'
        $preparedIntake = Invoke-ActivePrIntake `
            -Config $config -Provider $provider.Handler `
            -StateRoot $state -RepositoryRoot $repo `
            -MaximumHeadsThisRun 4 `
            -IncludeTransientSnapshots -Run
        $preparedIntake.transientSnapshots.Remove('4')
        Mock Invoke-OwnerV2PreviewRun `
            -ModuleName DevPilot.NamedAreEqualBridge {
            param(
                $StateRoot,
                $ManifestPath,
                $EnableLiveModel,
                $LiveAcquisitionProvider
            )
            $observationRoot = Join-Path $StateRoot `
                'mock\observations'
            New-Item -ItemType Directory `
                -Path $observationRoot -Force | Out-Null
            $records = @(
                1..3 | ForEach-Object {
                    $identity = ('{0:x64}' -f $_)
                    [IO.File]::WriteAllText(
                        (Join-Path $observationRoot `
                            "$identity.json"),
                        ([ordered]@{
                                subject = @{
                                    pullRequestId = $_
                                }
                                lifecycle = @{
                                    status = 'completed'
                                }
                                counts = @{
                                    unknown = 0
                                }
                                findingsComplete = $true
                                validationErrors = @()
                            } | ConvertTo-Json -Depth 8))
                    [pscustomobject]@{
                        identity = $identity
                        state = 'completed'
                        reason = 'unknown'
                    }
                })
            return [pscustomobject]@{
                records = $records
            }
        }

        $result = Invoke-NamedAreEqualCurrentPrBridge `
            -Config $config -Provider $provider.Handler `
            -StateRoot $state -ManifestPath $manifest `
            -RepositoryRoot $repo -MaximumHeadsThisRun 4 `
            -PreparedIntake $preparedIntake -Run

        $result.state | Should -BeExactly 'partial' `
            -Because ($result | ConvertTo-Json -Depth 8 -Compress)
        @($result.records) | Should -HaveCount 3
        $result.completedCount | Should -Be 2
        $result.incompleteCount | Should -Be 2
        @($result.records | Where-Object {
                [string]$_.state -ceq 'completed'
            }) | Should -HaveCount 2
        @($result.records | Where-Object {
                [string]$_.state -ceq 'unknown' -and
                [string]$_.reason -ceq
                    'post-evaluation-head-refused'
            }) | Should -HaveCount 1
        @($result.outcomes | Where-Object {
                $_ -is [Collections.IDictionary] -and
                $_.Contains('stage') -and
                [string]$_['stage'] -ceq 'snapshot' -and
                [long]$_['pullRequestId'] -eq 4 -and
                [string]$_['state'] -ceq 'unknown'
            }) | Should -HaveCount 1
        @($result.outcomes | Where-Object {
                $_ -is [Collections.IDictionary] -and
                $_.Contains('stage') -and
                [string]$_['stage'] -ceq 'post-head' -and
                [long]$_['pullRequestId'] -eq 3 -and
                [string]$_['state'] -ceq 'unknown'
            }) | Should -HaveCount 1
        @($provider.Calls | Where-Object {
                $_ -like 'Changes:*'
            }) | Should -HaveCount 4
        @($provider.Calls | Where-Object {
                $_ -like 'Discussions:*'
            }) | Should -HaveCount 4
    }

    It 'stops later identities after an ambiguous write' {
        $script:callCount = 0
        Mock Assert-AutomaticOwnerV2ServicePolicy {}
        Mock Invoke-AutomaticOwnerV2Comments {
            $script:callCount++
            return [pscustomobject]@{
                health = 'refused'
                providerWrites = 1
                modelWrites = 0
                remainingWouldCreate = 1
                events = @(@{
                        outcome =
                            'ambiguous-post-write'
                        providerWriteState = 'unknown'
                    })
            }
        }
        $evidence = @(1..4 | ForEach-Object {
                [pscustomobject]@{
                    Identity = ('{0:x64}' -f $_)
                    Observation = @{
                        findings = @(@{
                                reconciliation = @{
                                    classification =
                                        'wouldCreate'
                                }
                            })
                    }
                }
            })
        $result = Invoke-AutomaticNamedAreEqualBatch `
                -Evidence $evidence -Policy @{
                    limits = @{ maxCreatesPerRun = 2 }
                } `
            -DeliveryRoot $TestDrive -Key ([byte[]](1..32)) `
            -Provider { throw 'not invoked' } -MaximumCreates 2

        $result.health | Should -BeExactly 'refused'
        $result.providerWrites | Should -Be 1
        @($result.events) | Should -HaveCount 1
        @($result.deferred) | Should -HaveCount 3
        $script:callCount | Should -Be 1
    }

}
