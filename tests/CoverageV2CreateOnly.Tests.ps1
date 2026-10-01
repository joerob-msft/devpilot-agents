#requires -Version 7.0

Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) `
        'src\DevPilot.CoverageV2CreateOnly\DevPilot.CoverageV2CreateOnly.psm1') -Force

InModuleScope DevPilot.CoverageV2CreateOnly {
    BeforeAll {
        function New-FictionalCoverageCase {
            param([switch]$Redundant,
                [string]$Path = 'tests/FictionalSpec.cs')
            $rule = if ($Redundant) {
                'bpm-redundant-method-coverage@2'
            } else { 'bpm-test-class-coverage@2' }
            $head = @{
                repositoryId = '11111111-1111-1111-1111-111111111111'
                projectId = '22222222-2222-2222-2222-222222222222'
                pullRequestId = 42
                sourceRef = 'refs/heads/fictional-feature'
                sourceCommit = 'a' * 40
                targetRef = 'refs/heads/master'
                targetCommit = 'b' * 40
                currentTargetCommit = 'c' * 40
                iterationId = 3
                status = 'active'
                isDraft = $false
            }
            $intent = @{
                schemaVersion = 1
                kind = 'coverage-v2-unsigned-finding-candidate'
                ruleId = $rule
                path = $Path
                line = 12
                runId = 'fictional-run-1'
                discussionDigest = '7' * 64
                issuedUtc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
                expiresUtc = [DateTime]::UtcNow.AddMinutes(2).ToString(
                    'yyyy-MM-ddTHH:mm:ssZ')
                subject = $head.Clone()
                reviewer = @{
                    id = '33333333-3333-3333-3333-333333333333'
                    descriptor = 'fictional.reviewer'
                }
            }
            $intent.request = @{
                CapabilityId = $rule
                RuleSection = $rule
                RepositoryId = $head.repositoryId
                ProjectId = $head.projectId
                PullRequestId = 42
                SourceCommit = $head.sourceCommit
                TargetCommit = $head.targetCommit
                TargetRef = $head.targetRef
                RuleRepositoryId = '55555555-5555-5555-5555-555555555555'
                RulePath = 'fictional/coverage-rule.txt'
                RuleCommit = 'f' * 40
                RuleHash = 'v1:sha256:' + ('9' * 64)
                ConfigId = 'fictional-coverage-candidate'
            }
            $construct = 'construct:' + ('6' * 64)
            $intent.finding = @{
                disposition = 'violation'
                constructRef = $construct
                anchor = @{ path = $intent.path; line = 12
                    symbol = 'FictionalSpec' }
                binding = @{ source = @{ representation = @{
                            path = $intent.path
                            startLine = 12
                            endLine = 12
                            symbol = 'FictionalSpec'
                            constructIdentity = $construct
                        } } }
            }
            if ($Redundant) {
                $intent.finding.affectedMethods = @('FictionalTest')
                $intent.finding.affectedAttributeLines = @(12)
                $intent.finding.affectedMethodCount = 1
                $intent.finding.methodListTruncated = $false
            }
            $intent.proof = @{
                generation = '6' * 32
                sourceDigest = '9' * 64
                manifestDigest = '8' * 64
                graphDigest = '5' * 64
                principalDigest = '4' * 64
                discussionDigest = $intent.discussionDigest
                source = @{
                    ruleId = $rule
                    ruleCommit = $intent.request.RuleCommit
                    ruleHash = $intent.request.RuleHash
                    masterCommit = '1' * 40
                    digest = '9' * 64
                }
                manifest = @{
                    complete = $true
                    digest = '8' * 64
                    sourceCommit = $head.sourceCommit
                    path = $intent.path
                    line = 12
                }
                graph = @{
                    complete = $true
                    digest = '5' * 64
                    repositoryId = $head.repositoryId
                    sourceCommit = $head.sourceCommit
                }
                principal = @{
                    digest = '4' * 64
                    id = $intent.reviewer.id
                    descriptor = $intent.reviewer.descriptor
                }
                discussion = @{
                    complete = $true
                    digest = $intent.discussionDigest
                    sourceCommit = $head.sourceCommit
                    iterationId = 3
                }
                head = @{
                    sourceCommit = $head.sourceCommit
                    targetCommit = $head.targetCommit
                    currentTargetCommit = $head.currentTargetCommit
                    iterationId = 3
                }
                cohort = @{
                    generation = '6' * 32
                    runId = $intent.runId
                    populationKnown = $true
                    complete = $true
                    gaps = 0
                    rules = @('bpm-test-class-coverage@2',
                        'bpm-redundant-method-coverage@2')
                    passOne = @(42)
                    passTwo = @(42)
                    selected = @(42)
                }
            }
            $contract = [pscustomobject]@{
                Request = [pscustomobject]$intent.request
            }
            if ($Redundant) {
                $intent.marker = Get-RedundantMethodCoverageMarkerKey `
                    -Contract $contract -Finding $intent.finding
                $intent.body = Format-RedundantMethodCoverageComment `
                    -Contract $contract -Finding $intent.finding `
                    -MarkerKey $intent.marker
            } else {
                $intent.marker = Get-TestClassCoverageMarkerKey `
                    -Contract $contract -Finding $intent.finding
                $intent.body = Format-TestClassCoverageComment `
                    -Contract $contract -Finding $intent.finding `
                    -MarkerKey $intent.marker
            }
            $intent.findingDigest = Get-AgentCanonicalDigest -InputObject (
                [ordered]@{ ruleId = $rule
                    request = $intent.request
                    finding = $intent.finding
                    proof = $intent.proof })
            return @{
                Intent = $intent
                CurrentHead = $head
                CurrentBearer = $intent.reviewer.Clone()
                Human = @{
                    id = '44444444-4444-4444-4444-444444444444'
                    descriptor = 'fictional.human'
                }
                Snapshot = @{
                    complete = $true
                    generation = $intent.proof.generation
                    sourceCommit = $head.sourceCommit
                    iterationId = $head.iterationId
                    digest = $intent.discussionDigest
                    threads = @()
                }
                Ledger = @{
                    schemaVersion = 1
                    complete = $true
                    scope = @{
                        kind = 'complete-rule-run-and-rule-pr-history-v1'
                        repositoryId = $head.repositoryId
                        pullRequestId = 42
                        ruleId = $rule
                        runId = $intent.runId
                        runComplete = $true
                        rulePrComplete = $true
                        scannedPullRequestIds = @(42)
                    }
                    entries = @()
                }
            }
        }

        function New-FictionalLedgerEntry {
            param($Case, [string]$Marker, [string]$RunId,
                [string]$RuleId)
            return @{
                repositoryId = $Case.Intent.subject.repositoryId
                pullRequestId = 42
                ruleId = $RuleId
                marker = $Marker
                runId = $RunId
                state = 'ambiguous'
            }
        }

        function New-FictionalHumanThread {
            param($Case, [switch]$Redundant)
            return @{
                anchor = @{ path = $Case.Intent.path; line = 12 }
                status = 'active'
                contextState = 'current'
                sourceCommit = $Case.Intent.subject.sourceCommit
                isDeleted = $false
                isOutdated = $false
                comments = @(@{
                    author = $Case.Human.Clone()
                    body = $(if ($Redundant) {
                        'Please remove redundant method-level coverage exclusion since the class is already excluded.'
                    } else {
                        'Please exclude from code coverage.'
                    })
                    reviewerIdentityState = 'matched'
                    commentType = 'text'
                    isDeleted = $false
                })
            }
        }
    }

    Describe 'isolated coverage @2 create-only offline contract' {
        It 'is unexported and default OFF' {
            (Get-Module DevPilot.CoverageV2CreateOnly).ExportedCommands.Count |
                Should -Be 0
            $c = New-FictionalCoverageCase
            { Invoke-CoverageV2CreateOnly -Intent $c.Intent } |
                Should -Throw '*coverage-v2-writer-disabled*'
            { Invoke-CoverageV2CreateOnly @c -Config @{
                    enabled = 'true'
                    mode = 'coverage-v2-create-only'
                } } | Should -Throw '*coverage-v2-writer-disabled*'
        }

        It 'recognizes each of the two distinct @2 rules without authorizing a write' -ForEach @(
            @{ Redundant = $false },
            @{ Redundant = $true }
        ) {
            $c = New-FictionalCoverageCase -Redundant:$Redundant
            Get-CoverageV2OfflineDecision @c | Should -Be 'wouldCreate'
            { Invoke-CoverageV2CreateOnly @c -Config @{
                    enabled = $true
                    mode = 'coverage-v2-create-only'
                    signedVerified = $true
                } } | Should -Throw '*coverage-v2-intent-source-ledger-authority-unavailable*'
        }

        It 'recognizes a fictional uppercase .CS suffix without folding the Git path' {
            $c = New-FictionalCoverageCase -Path 'tests/FictionalSpec.CS'
            Get-CoverageV2OfflineDecision @c | Should -Be 'wouldCreate'
            $c = New-FictionalCoverageCase -Redundant `
                -Path 'tests/RedundantFiction.CS'
            Get-CoverageV2OfflineDecision @c | Should -Be 'wouldCreate'
        }

        It 'rejects @1, Owner, Named, a wrong @2 marker and a second marker' {
            foreach ($rule in @('bpm-test-class-coverage@1',
                    'bpm-test-ownership@1', 'bpm-named-areequal-arguments@1')) {
                $c = New-FictionalCoverageCase
                $c.Intent.ruleId = $rule
                { Get-CoverageV2OfflineDecision @c } |
                    Should -Throw '*coverage-v2-finding-ambiguous*'
            }
            $c = New-FictionalCoverageCase
            $c.Intent.body = $c.Intent.body.Replace(':v2:', ':v1:')
            { Get-CoverageV2OfflineDecision @c } |
                Should -Throw '*coverage-v2-marker-ambiguous*'
            $c = New-FictionalCoverageCase
            $c.Intent.body += "`n<!-- devpilot-test-class-coverage:v2:$('f' * 64) -->"
            { Get-CoverageV2OfflineDecision @c } |
                Should -Throw '*coverage-v2-marker-ambiguous*'
        }

        It 'never mistakes schema-9 canary results or aggregate counts for a finding' {
            $c = New-FictionalCoverageCase
            $c.Intent.schemaVersion = 9
            $c.Intent.kind = 'private-coverage-only-read-only-evaluation'
            { Get-CoverageV2OfflineDecision @c } |
                Should -Throw '*coverage-v2-finding-ambiguous*'
            $c = New-FictionalCoverageCase
            $c.Intent.writerEligible = $true
            $c.Intent.wouldCreate = 2
            { Get-CoverageV2OfflineDecision @c } |
                Should -Throw '*coverage-v2-finding-ambiguous*'
            $c = New-FictionalCoverageCase
            $c.Intent.kind = 'coverage-v2-service-create-intent'
            { Get-CoverageV2OfflineDecision @c } |
                Should -Throw '*coverage-v2-finding-ambiguous*'
        }

        It 'requires a complete two-pass cohort and the current generation' {
            $c = New-FictionalCoverageCase
            $c.Intent.proof.cohort.passTwo = @(42, 43)
            { Get-CoverageV2OfflineDecision @c } |
                Should -Throw '*coverage-v2-two-pass-cohort-incomplete*'
            $c = New-FictionalCoverageCase
            $c.Intent.proof.cohort.selected = @()
            { Get-CoverageV2OfflineDecision @c } |
                Should -Throw '*coverage-v2-two-pass-cohort-incomplete*'
            $c = New-FictionalCoverageCase
            $c.Intent.proof.cohort.rules = @('bpm-test-class-coverage@2')
            { Get-CoverageV2OfflineDecision @c } |
                Should -Throw '*coverage-v2-two-pass-cohort-incomplete*'
            $c = New-FictionalCoverageCase
            $c.Snapshot.generation = 'a' * 32
            { Get-CoverageV2OfflineDecision @c } |
                Should -Throw '*coverage-v2-discussions-ambiguous*'
        }

        It 'recomputes @2 marker and body from the full bound finding' {
            $c = New-FictionalCoverageCase
            $c.Intent.body = 'Tampered fictional suggestion' + "`n" +
                "<!-- devpilot-test-class-coverage:v2:$($c.Intent.marker) -->"
            { Get-CoverageV2OfflineDecision @c } |
                Should -Throw '*coverage-v2-marker-or-body-mismatch*'
            $c = New-FictionalCoverageCase -Redundant
            $c.Intent.finding.affectedAttributeLines = @(13)
            { Get-CoverageV2OfflineDecision @c } |
                Should -Throw '*coverage-v2-finding-digest-mismatch*'
        }

        It 'rejects contradictory source, manifest, graph or discussion receipts' {
            foreach ($field in @('source', 'manifest', 'graph', 'discussion')) {
                $c = New-FictionalCoverageCase
                switch ($field) {
                    'source' { $c.Intent.proof.source.ruleCommit = '2' * 40 }
                    'manifest' {
                        $c.Intent.proof.manifest.sourceCommit = '2' * 40
                    }
                    'graph' { $c.Intent.proof.graph.repositoryId =
                            '77777777-7777-7777-7777-777777777777' }
                    'discussion' {
                        $c.Intent.proof.discussion.iterationId = 4
                    }
                }
                { Get-CoverageV2OfflineDecision @c } |
                    Should -Throw '*coverage-v2-bound-finding-or-cohort-ambiguous*'
            }
        }

        It 'refuses drift of source, current target, iteration, and same-bearer identity' {
            foreach ($field in @('sourceCommit', 'currentTargetCommit',
                    'iterationId')) {
                $c = New-FictionalCoverageCase
                $c.CurrentHead[$field] = if ($field -eq 'iterationId') {
                    4
                } else { 'f' * 40 }
                { Get-CoverageV2OfflineDecision @c } |
                    Should -Throw '*coverage-v2-head-drift*'
            }
            foreach ($field in @('id', 'descriptor')) {
                $c = New-FictionalCoverageCase
                $c.CurrentBearer[$field] = if ($field -eq 'id') {
                    '55555555-5555-5555-5555-555555555555'
                } else { 'fictional.other' }
                { Get-CoverageV2OfflineDecision @c } |
                    Should -Throw '*coverage-v2-principal-ambiguous*'
            }
            $c = New-FictionalCoverageCase
            $c.Snapshot.digest = '8' * 64
            { Get-CoverageV2OfflineDecision @c } |
                Should -Throw '*coverage-v2-discussions-ambiguous*'
            $c = New-FictionalCoverageCase
            $c.CurrentHead.isDraft = $true
            { Get-CoverageV2OfflineDecision @c } |
                Should -Throw '*coverage-v2-head-ambiguous*'
            $c = New-FictionalCoverageCase
            $c.Intent.expiresUtc = [DateTime]::UtcNow.AddMinutes(-1).ToString(
                'yyyy-MM-ddTHH:mm:ssZ')
            { Get-CoverageV2OfflineDecision @c } |
                Should -Throw '*coverage-v2-intent-expired-or-ambiguous*'
        }

        It 'requires a complete ledger and counts uncertain attempts per rule across heads' {
            $c = New-FictionalCoverageCase
            $c.Ledger.complete = $false
            { Get-CoverageV2OfflineDecision @c } |
                Should -Throw '*coverage-v2-ledger-unavailable*'
            $c = New-FictionalCoverageCase
            $c.Ledger.entries = @(
                (New-FictionalLedgerEntry $c $c.Intent.marker 'old-run' $c.Intent.ruleId))
            { Get-CoverageV2OfflineDecision @c } |
                Should -Throw '*coverage-v2-retry-forbidden*'
            $c = New-FictionalCoverageCase
            $c.Ledger.entries = @(
                (New-FictionalLedgerEntry $c ('1' * 64) $c.Intent.runId $c.Intent.ruleId),
                (New-FictionalLedgerEntry $c ('2' * 64) $c.Intent.runId $c.Intent.ruleId))
            { Get-CoverageV2OfflineDecision @c } |
                Should -Throw '*coverage-v2-create-budget-exhausted*'
            $c = New-FictionalCoverageCase
            $other = 'bpm-redundant-method-coverage@2'
            $c.Ledger.entries = @(
                (New-FictionalLedgerEntry $c ('1' * 64) 'old-run' $other),
                (New-FictionalLedgerEntry $c ('2' * 64) 'old-run' $other),
                (New-FictionalLedgerEntry $c ('3' * 64) 'old-run' $other),
                (New-FictionalLedgerEntry $c ('4' * 64) 'old-run' $other),
                (New-FictionalLedgerEntry $c ('5' * 64) 'old-run' $other))
            Get-CoverageV2OfflineDecision @c | Should -Be 'wouldCreate'
            $c.Ledger.entries = @(
                (New-FictionalLedgerEntry $c ('1' * 64) 'old-run' $c.Intent.ruleId),
                (New-FictionalLedgerEntry $c ('2' * 64) 'old-run' $c.Intent.ruleId),
                (New-FictionalLedgerEntry $c ('3' * 64) 'old-run' $c.Intent.ruleId),
                (New-FictionalLedgerEntry $c ('4' * 64) 'old-run' $c.Intent.ruleId),
                (New-FictionalLedgerEntry $c ('5' * 64) 'old-run' $c.Intent.ruleId))
            { Get-CoverageV2OfflineDecision @c } |
                Should -Throw '*coverage-v2-create-budget-exhausted*'
        }

        It 'counts rule/run reservations across PRs while keeping rule/PR caps independent' {
            $c = New-FictionalCoverageCase
            $c.Ledger.scope.scannedPullRequestIds = @(42, 43, 44)
            $first = New-FictionalLedgerEntry $c ('1' * 64) `
                $c.Intent.runId $c.Intent.ruleId
            $first.pullRequestId = 43
            $second = New-FictionalLedgerEntry $c ('2' * 64) `
                $c.Intent.runId $c.Intent.ruleId
            $second.pullRequestId = 44
            $c.Ledger.entries = @($first, $second)
            { Get-CoverageV2OfflineDecision @c } |
                Should -Throw '*coverage-v2-create-budget-exhausted*'
            $c.Ledger.scope.runComplete = $false
            { Get-CoverageV2OfflineDecision @c } |
                Should -Throw '*coverage-v2-ledger-unavailable*'
            $c.Ledger.scope.runComplete = $true
            $c.Ledger.scope.scannedPullRequestIds = @(42, 43)
            { Get-CoverageV2OfflineDecision @c } |
                Should -Throw '*coverage-v2-ledger-run-history-incomplete*'
            $c.Ledger.scope.scannedPullRequestIds = @(42, 43, 44)
            $c.Ledger.scope.runId = 'fictional-run-2'
            $c.Intent.runId = 'fictional-run-2'
            $c.Intent.proof.cohort.runId = 'fictional-run-2'
            $c.Intent.findingDigest = Get-AgentCanonicalDigest -InputObject (
                [ordered]@{ ruleId = $c.Intent.ruleId
                    request = $c.Intent.request
                    finding = $c.Intent.finding
                    proof = $c.Intent.proof })
            Get-CoverageV2OfflineDecision @c | Should -Be 'wouldCreate'
            $c.Ledger.scope.ruleId = 'bpm-redundant-method-coverage@2'
            { Get-CoverageV2OfflineDecision @c } |
                Should -Throw '*coverage-v2-ledger-unavailable*'
        }

        It 'treats one matching HUMAN GUID and descriptor as covered, not as create eligible' {
            $c = New-FictionalCoverageCase
            $c.Snapshot.threads = @((New-FictionalHumanThread $c))
            Get-CoverageV2OfflineDecision @c | Should -Be 'humanCovered'
            $c = New-FictionalCoverageCase -Redundant
            $c.Snapshot.threads = @((New-FictionalHumanThread $c -Redundant))
            Get-CoverageV2OfflineDecision @c | Should -Be 'humanCovered'
        }

        It 'refuses negated or incomplete HUMAN coverage advice as ambiguous' {
            foreach ($case in @(
                    @{ Redundant = $false
                        Body = 'Do not exclude from code coverage.' },
                    @{ Redundant = $true
                        Body = 'Fictional method attribute has redundant coverage exclusion.' },
                    @{ Redundant = $true
                        Body = 'Do not remove the redundant method coverage exclusion from this class.' },
                    @{ Redundant = $true
                        Body = 'Should we remove redundant method-level coverage exclusion from this class?' }
                )) {
                $c = New-FictionalCoverageCase -Redundant:([bool]$case.Redundant)
                $thread = New-FictionalHumanThread $c -Redundant:([bool]$case.Redundant)
                $thread.comments[0].body = $case.Body
                $c.Snapshot.threads = @($thread)
                { Get-CoverageV2OfflineDecision @c } |
                    Should -Throw '*coverage-v2-human-ambiguous*'
            }
        }

        It 'requires current context and unambiguous matched HUMAN identity' {
            foreach ($field in @('contextState', 'reviewerIdentityState')) {
                foreach ($state in @('outdated', 'ambiguous', $null)) {
                    $c = New-FictionalCoverageCase
                    $thread = New-FictionalHumanThread $c
                    if ($field -ceq 'contextState') {
                        $thread.contextState = $state
                    } else {
                        $thread.comments[0].reviewerIdentityState = $state
                    }
                    $c.Snapshot.threads = @($thread)
                    { Get-CoverageV2OfflineDecision @c } |
                        Should -Throw '*coverage-v2-human-ambiguous*'
                }
            }
        }

        It 'refuses alias, partial identity, legacy marker, duplicate and stale discussion' {
            $c = New-FictionalCoverageCase
            $c.Snapshot.threads = @((New-FictionalHumanThread $c))
            $c.Snapshot.threads[0].comments[0].author.descriptor = 'fictional.alias'
            { Get-CoverageV2OfflineDecision @c } |
                Should -Throw '*coverage-v2-principal-ambiguous*'
            $c = New-FictionalCoverageCase
            $c.Human.id = $c.Intent.reviewer.id
            { Get-CoverageV2OfflineDecision @c } |
                Should -Throw '*coverage-v2-human-ambiguous*'
            $c = New-FictionalCoverageCase
            $c.Snapshot.threads = @((New-FictionalHumanThread $c))
            $c.Snapshot.threads[0].isOutdated = $true
            { Get-CoverageV2OfflineDecision @c } |
                Should -Throw '*coverage-v2-discussions-ambiguous*'
            $c = New-FictionalCoverageCase
            $thread = New-FictionalHumanThread $c
            $thread.comments[0].body = "<!-- devpilot-test-class-coverage:v1:$('f' * 64) -->"
            $c.Snapshot.threads = @($thread)
            { Get-CoverageV2OfflineDecision @c } |
                Should -Throw '*coverage-v2-marker-present-or-ambiguous*'
            $c = New-FictionalCoverageCase
            $c.Snapshot.threads = @(
                (New-FictionalHumanThread $c), (New-FictionalHumanThread $c))
            { Get-CoverageV2OfflineDecision @c } |
                Should -Throw '*coverage-v2-discussions-ambiguous*'
        }

        It 'refuses a HUMAN thread on a distinct case-variant Git path' {
            $c = New-FictionalCoverageCase
            $thread = New-FictionalHumanThread $c
            $thread.anchor.path = 'tests/FICTIONALSpec.cs'
            $c.Snapshot.threads = @($thread)
            { Get-CoverageV2OfflineDecision @c } |
                Should -Throw '*coverage-v2-discussions-ambiguous*'
        }

        It 'refuses case-variant and malformed automation markers off-anchor' {
            foreach ($body in @(
                    "<!-- DEVPILOT-TEST-CLASS-COVERAGE:V2:$('F' * 64) -->",
                    '<!-- devpilot-test-class-coverage:v2:not-a-hash -->',
                    '<!-- devpilot-redundant-method-coverage:v2:unfinished'
                )) {
                $c = New-FictionalCoverageCase
                $thread = New-FictionalHumanThread $c
                $thread.anchor.path = 'tests/AnotherFiction.cs'
                $thread.comments[0].body = $body
                $c.Snapshot.threads = @($thread)
                { Get-CoverageV2OfflineDecision @c } |
                    Should -Throw '*coverage-v2-marker-present-or-ambiguous*'
            }
        }
    }
}
