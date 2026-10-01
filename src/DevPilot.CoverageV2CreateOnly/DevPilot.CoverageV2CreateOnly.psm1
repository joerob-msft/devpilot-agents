#requires -Version 7.0
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot `
        '..\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1')
Import-Module (Join-Path $PSScriptRoot `
        '..\DevPilot.OwnerCapability\DevPilot.OwnerCapability.psd1')

$script:CoverageV2Prefixes = @{
    'bpm-test-class-coverage@2' = 'devpilot-test-class-coverage:v2'
    'bpm-redundant-method-coverage@2' = 'devpilot-redundant-method-coverage:v2'
}

function Assert-CoverageV2Identity {
    param([Collections.IDictionary]$Actual, [Collections.IDictionary]$Expected)
    if ($null -eq $Actual -or $null -eq $Expected -or
        [string]$Expected.id -cnotmatch
            '^[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$' -or
        [string]$Expected.descriptor -cnotmatch '^[A-Za-z0-9._-]{1,512}$' -or
        [string]$Actual.id -cne [string]$Expected.id -or
        [string]$Actual.descriptor -cne [string]$Expected.descriptor) {
        throw 'coverage-v2-principal-ambiguous'
    }
}

function Assert-CoverageV2Head {
    param([Collections.IDictionary]$Expected, [Collections.IDictionary]$Current)
    if ($null -eq $Expected -or $null -eq $Current -or
        [string]$Current.status -cne 'active' -or
        $Current.isDraft -isnot [bool] -or $Current.isDraft -cne $false -or
        [string]$Expected.sourceCommit -cnotmatch '^[a-f0-9]{40}$' -or
        [string]$Expected.currentTargetCommit -cnotmatch '^[a-f0-9]{40}$' -or
        [string]$Expected.targetCommit -cnotmatch '^[a-f0-9]{40}$' -or
        [string]$Expected.targetRef -cne 'refs/heads/master' -or
        [string]$Expected.sourceRef -cnotmatch
            '^refs/heads/[A-Za-z0-9._/-]{1,480}$' -or
        [string]$Expected.repositoryId -cnotmatch
            '^[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$' -or
        [string]$Expected.projectId -cnotmatch
            '^[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$' -or
        [string]$Expected.pullRequestId -cnotmatch '^[1-9][0-9]*$' -or
        [string]$Expected.iterationId -cnotmatch '^[1-9][0-9]*$') {
        throw 'coverage-v2-head-ambiguous'
    }
    foreach ($field in @('repositoryId', 'projectId', 'pullRequestId',
            'sourceRef', 'sourceCommit', 'targetRef', 'targetCommit',
            'currentTargetCommit', 'iterationId')) {
        if ([string]$Expected[$field] -cne [string]$Current[$field]) {
            throw 'coverage-v2-head-drift'
        }
    }
}

function Assert-CoverageV2LedgerBudget {
    param([Collections.IDictionary]$Ledger, [Collections.IDictionary]$Subject,
        [string]$RuleId, [string]$RunId, [string]$Marker,
        [object[]]$ExpectedRunPullRequestIds)
    $scope = $Ledger.scope
    if ($null -eq $Ledger -or $Ledger.schemaVersion -cne 1 -or
        $Ledger.complete -isnot [bool] -or
        $Ledger.complete -cne $true -or $Ledger.entries -isnot [array] -or
        $Ledger.entries.Count -gt 10000 -or
        $scope -isnot [Collections.IDictionary] -or
        [string]$scope.kind -cne 'complete-rule-run-and-rule-pr-history-v1' -or
        [string]$scope.repositoryId -cne [string]$Subject.repositoryId -or
        [string]$scope.ruleId -cne $RuleId -or
        [string]$scope.runId -cne $RunId -or
        [string]$scope.pullRequestId -cne
            [string]$Subject.pullRequestId -or
        $scope.runComplete -cne $true -or
        $scope.rulePrComplete -cne $true -or
        $scope.scannedPullRequestIds -isnot [array] -or
        $scope.scannedPullRequestIds.Count -lt 1 -or
        $scope.scannedPullRequestIds.Count -gt 2000 -or
        [string]$RunId -cnotmatch '^[A-Za-z0-9-]{1,80}$') {
        throw 'coverage-v2-ledger-unavailable'
    }
    $scanned = @($scope.scannedPullRequestIds | ForEach-Object {
            [string]$_ })
    if (@($scanned | Where-Object { $_ -cnotmatch '^[1-9][0-9]*$' }).Count -gt 0 -or
        @($scanned | Select-Object -Unique).Count -ne $scanned.Count -or
        [string]$Subject.pullRequestId -cnotin $scanned -or
        @($ExpectedRunPullRequestIds | Where-Object {
                [string]$_ -cnotin $scanned }).Count -gt 0) {
        throw 'coverage-v2-ledger-run-history-incomplete'
    }
    $rulePrCount = 0
    $ruleRunCount = 0
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($entry in $Ledger.entries) {
        if ($entry -isnot [Collections.IDictionary] -or
            [string]$entry.repositoryId -cnotmatch
                '^[0-9a-fA-F-]{36}$' -or
            [string]$entry.pullRequestId -cnotmatch '^[1-9][0-9]*$' -or
            [string]$entry.ruleId -cnotin @($script:CoverageV2Prefixes.Keys) -or
            [string]$entry.marker -cnotmatch '^[a-f0-9]{64}$' -or
            [string]$entry.runId -cnotmatch '^[A-Za-z0-9-]{1,80}$' -or
            [string]$entry.state -cnotin @(
                'reserved', 'attempted', 'confirmed', 'ambiguous'
            ) -or
            -not $seen.Add(('{0}:{1}:{2}:{3}' -f $entry.repositoryId,
                        $entry.pullRequestId, $entry.ruleId, $entry.marker))) {
            throw 'coverage-v2-ledger-ambiguous'
        }
        if ([string]$entry.repositoryId -cne [string]$Subject.repositoryId) {
            continue
        }
        if ([string]$entry.ruleId -ceq $RuleId -and
            [string]$entry.runId -ceq $RunId) {
            if ([string]$entry.pullRequestId -cnotin $scanned) {
                throw 'coverage-v2-ledger-run-history-incomplete'
            }
            $ruleRunCount++
        }
        if ([string]$entry.pullRequestId -cne
            [string]$Subject.pullRequestId) {
            continue
        }
        if ([string]$entry.marker -ceq $Marker) {
            throw 'coverage-v2-retry-forbidden'
        }
        # Reservations and ambiguous attempts consume this rule's PR bucket
        # across all heads and runs, not the other rule's independent bucket.
        if ([string]$entry.ruleId -ceq $RuleId) {
            $rulePrCount++
        }
    }
    if ($ruleRunCount -ge 2 -or $rulePrCount -ge 5) {
        throw 'coverage-v2-create-budget-exhausted'
    }
}

function Assert-CoverageV2BoundCandidate {
    param([Collections.IDictionary]$Intent)
    $request = $Intent.request
    $finding = $Intent.finding
    $proof = $Intent.proof
    $cohort = $proof.cohort
    $source = $proof.source
    $manifest = $proof.manifest
    $graph = $proof.graph
    $principal = $proof.principal
    $discussion = $proof.discussion
    $head = $proof.head
    if ($request -isnot [Collections.IDictionary] -or
        $finding -isnot [Collections.IDictionary] -or
        $proof -isnot [Collections.IDictionary] -or
        $cohort -isnot [Collections.IDictionary] -or
        $source -isnot [Collections.IDictionary] -or
        $manifest -isnot [Collections.IDictionary] -or
        $graph -isnot [Collections.IDictionary] -or
        $principal -isnot [Collections.IDictionary] -or
        $discussion -isnot [Collections.IDictionary] -or
        $head -isnot [Collections.IDictionary] -or
        [string]$request.CapabilityId -cne [string]$Intent.ruleId -or
        [string]$request.RuleSection -cne [string]$Intent.ruleId -or
        [string]$request.RepositoryId -cne [string]$Intent.subject.repositoryId -or
        [string]$request.ProjectId -cne [string]$Intent.subject.projectId -or
        [string]$request.PullRequestId -cne [string]$Intent.subject.pullRequestId -or
        [string]$request.SourceCommit -cne [string]$Intent.subject.sourceCommit -or
        [string]$request.TargetCommit -cne [string]$Intent.subject.targetCommit -or
        [string]$request.TargetRef -cne [string]$Intent.subject.targetRef -or
        [string]$request.RuleHash -cnotmatch '^v1:sha256:[a-f0-9]{64}$' -or
        [string]$request.RuleCommit -cnotmatch '^[a-f0-9]{40}$' -or
        [string]$finding.anchor.path -cne [string]$Intent.path -or
        [string]$finding.anchor.line -cne [string]$Intent.line -or
        [string]$proof.generation -cnotmatch '^[a-f0-9]{32}$' -or
        [string]$proof.sourceDigest -cnotmatch '^[a-f0-9]{64}$' -or
        [string]$proof.manifestDigest -cnotmatch '^[a-f0-9]{64}$' -or
        [string]$proof.graphDigest -cnotmatch '^[a-f0-9]{64}$' -or
        [string]$proof.principalDigest -cnotmatch '^[a-f0-9]{64}$' -or
        [string]$proof.discussionDigest -cne
            [string]$Intent.discussionDigest -or
        [string]$source.ruleId -cne [string]$Intent.ruleId -or
        [string]$source.ruleCommit -cne [string]$request.RuleCommit -or
        [string]$source.ruleHash -cne [string]$request.RuleHash -or
        [string]$source.masterCommit -cnotmatch '^[a-f0-9]{40}$' -or
        [string]$source.digest -cne [string]$proof.sourceDigest -or
        $manifest.complete -cne $true -or
        [string]$manifest.digest -cne [string]$proof.manifestDigest -or
        [string]$manifest.sourceCommit -cne
            [string]$Intent.subject.sourceCommit -or
        [string]$manifest.path -cne [string]$Intent.path -or
        [string]$manifest.line -cne [string]$Intent.line -or
        $graph.complete -cne $true -or
        [string]$graph.digest -cne [string]$proof.graphDigest -or
        [string]$graph.repositoryId -cne
            [string]$Intent.subject.repositoryId -or
        [string]$graph.sourceCommit -cne
            [string]$Intent.subject.sourceCommit -or
        [string]$principal.digest -cne [string]$proof.principalDigest -or
        [string]$principal.id -cne [string]$Intent.reviewer.id -or
        [string]$principal.descriptor -cne
            [string]$Intent.reviewer.descriptor -or
        $discussion.complete -cne $true -or
        [string]$discussion.digest -cne
            [string]$Intent.discussionDigest -or
        [string]$discussion.sourceCommit -cne
            [string]$Intent.subject.sourceCommit -or
        [string]$discussion.iterationId -cne
            [string]$Intent.subject.iterationId -or
        [string]$head.sourceCommit -cne
            [string]$Intent.subject.sourceCommit -or
        [string]$head.targetCommit -cne
            [string]$Intent.subject.targetCommit -or
        [string]$head.currentTargetCommit -cne
            [string]$Intent.subject.currentTargetCommit -or
        [string]$head.iterationId -cne
            [string]$Intent.subject.iterationId -or
        [string]$cohort.generation -cne [string]$proof.generation -or
        [string]$cohort.runId -cne [string]$Intent.runId -or
        $cohort.populationKnown -cne $true -or
        $cohort.complete -cne $true -or
        $cohort.gaps -cne 0 -or
        $cohort.rules -isnot [array] -or
        $cohort.passOne -isnot [array] -or
        $cohort.passTwo -isnot [array] -or
        $cohort.selected -isnot [array]) {
        throw 'coverage-v2-bound-finding-or-cohort-ambiguous'
    }
    $first = @($cohort.passOne)
    $second = @($cohort.passTwo)
    $selected = @($cohort.selected)
    if ((@($cohort.rules | Sort-Object) -join ',') -cne
        (@($script:CoverageV2Prefixes.Keys | Sort-Object) -join ',') -or
        @($cohort.rules).Count -ne 2 -or
        $first.Count -lt 1 -or $first.Count -gt 2000 -or
        $first.Count -ne $second.Count -or
        $first.Count -ne $selected.Count -or
        @($first | Where-Object { [string]$_ -cnotmatch '^[1-9][0-9]*$' }).Count -gt 0 -or
        @($first | Select-Object -Unique).Count -ne $first.Count -or
        (@($first | Sort-Object) -join ',') -cne
            (@($second | Sort-Object) -join ',') -or
        (@($first | Sort-Object) -join ',') -cne
            (@($selected | Sort-Object) -join ',') -or
        [string]$Intent.subject.pullRequestId -cnotin
            @($first | ForEach-Object { [string]$_ })) {
        throw 'coverage-v2-two-pass-cohort-incomplete'
    }
    $material = [ordered]@{ ruleId = [string]$Intent.ruleId
        request = $request; finding = $finding; proof = $proof }
    if ((Get-AgentCanonicalDigest -InputObject $material) -cne
        [string]$Intent.findingDigest) {
        throw 'coverage-v2-finding-digest-mismatch'
    }
    $contract = [pscustomobject]@{ Request = [pscustomobject]$request }
    try {
        $expectedMarker = if ($Intent.ruleId -ceq
            'bpm-test-class-coverage@2') {
            Get-TestClassCoverageMarkerKey -Contract $contract -Finding $finding
        } else {
            Get-RedundantMethodCoverageMarkerKey -Contract $contract -Finding $finding
        }
        $expectedBody = if ($Intent.ruleId -ceq
            'bpm-test-class-coverage@2') {
            Format-TestClassCoverageComment -Contract $contract `
                -Finding $finding -MarkerKey $expectedMarker
        } else {
            Format-RedundantMethodCoverageComment -Contract $contract `
                -Finding $finding -MarkerKey $expectedMarker
        }
    }
    catch { throw 'coverage-v2-bound-finding-or-cohort-ambiguous' }
    if ([string]$Intent.marker -cne $expectedMarker -or
        [string]$Intent.body -cne $expectedBody) {
        throw 'coverage-v2-marker-or-body-mismatch'
    }
}

function Get-CoverageV2OfflineDecision {
    param(
        [Collections.IDictionary]$Intent,
        [Collections.IDictionary]$CurrentHead,
        [Collections.IDictionary]$CurrentBearer,
        [Collections.IDictionary]$Human,
        [Collections.IDictionary]$Snapshot,
        [Collections.IDictionary]$Ledger
    )
    $candidateKeys = @('schemaVersion', 'kind', 'ruleId', 'findingDigest',
        'marker', 'path', 'line', 'body', 'runId', 'discussionDigest',
        'issuedUtc', 'expiresUtc', 'subject', 'reviewer', 'request', 'finding',
        'proof')
    if ($null -eq $Intent -or $Intent.Count -ne $candidateKeys.Count -or
        @($Intent.Keys | Where-Object { [string]$_ -cnotin $candidateKeys }).Count -gt 0 -or
        $Intent.schemaVersion -cne 1 -or
        [string]$Intent.kind -cne 'coverage-v2-unsigned-finding-candidate' -or
        [string]$Intent.ruleId -cnotin @($script:CoverageV2Prefixes.Keys) -or
        [string]$Intent.findingDigest -cnotmatch '^[a-f0-9]{64}$' -or
        [string]$Intent.marker -cnotmatch '^[a-f0-9]{64}$' -or
        [string]$Intent.path -cnotmatch
            '^[A-Za-z0-9_./-]{1,512}(?i:\.cs)$' -or
        [string]$Intent.path -cmatch '(^/|(^|/)\.\.?(/|$))' -or
        [string]$Intent.line -cnotmatch '^[1-9][0-9]*$' -or
        $Intent.body -isnot [string] -or
        $Intent.body.Length -gt 8192 -or
        [string]$Intent.discussionDigest -cnotmatch '^[a-f0-9]{64}$' -or
        [string]$Intent.runId -cnotmatch '^[A-Za-z0-9-]{1,80}$') {
        throw 'coverage-v2-finding-ambiguous'
    }
    try {
        $issued = [DateTime]::ParseExact([string]$Intent.issuedUtc,
            'yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture,
            ([Globalization.DateTimeStyles]::AssumeUniversal -bor
                [Globalization.DateTimeStyles]::AdjustToUniversal))
        $expires = [DateTime]::ParseExact([string]$Intent.expiresUtc,
            'yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture,
            ([Globalization.DateTimeStyles]::AssumeUniversal -bor
                [Globalization.DateTimeStyles]::AdjustToUniversal))
    }
    catch { throw 'coverage-v2-intent-expired-or-ambiguous' }
    $now = [DateTime]::UtcNow
    if ($issued -gt $now -or $issued -lt $now.AddMinutes(-5) -or
        $expires -le $now -or $expires -le $issued -or
        $expires -gt $issued.AddMinutes(5)) {
        throw 'coverage-v2-intent-expired-or-ambiguous'
    }
    $prefix = $script:CoverageV2Prefixes[[string]$Intent.ruleId]
    $exact = "<!-- ${prefix}:$($Intent.marker) -->"
    $allMarkers = [regex]::Matches([string]$Intent.body,
        '<!--\s*devpilot-[^>]*-->')
    if ($allMarkers.Count -ne 1 -or
        [string]$allMarkers[0].Value -cne $exact -or
        -not ([string]$Intent.body).EndsWith($exact, [StringComparison]::Ordinal)) {
        throw 'coverage-v2-marker-ambiguous'
    }
    Assert-CoverageV2BoundCandidate $Intent
    Assert-CoverageV2Head $Intent.subject $CurrentHead
    Assert-CoverageV2Identity $CurrentBearer $Intent.reviewer
    Assert-CoverageV2Identity $Human $Human
    if ([string]$Human.id -ceq [string]$Intent.reviewer.id -or
        [string]$Human.descriptor -ceq [string]$Intent.reviewer.descriptor) {
        throw 'coverage-v2-human-ambiguous'
    }
    Assert-CoverageV2LedgerBudget $Ledger $Intent.subject `
        ([string]$Intent.ruleId) ([string]$Intent.runId) ([string]$Intent.marker) `
        @($Intent.proof.cohort.selected)
    if ($null -eq $Snapshot -or $Snapshot.complete -isnot [bool] -or
        $Snapshot.complete -cne $true -or
        $Snapshot.threads -isnot [array] -or
        $Snapshot.threads.Count -gt 2000 -or
        [string]$Snapshot.generation -cne [string]$Intent.proof.generation -or
        [string]$Snapshot.digest -cne [string]$Intent.discussionDigest -or
        [string]$Snapshot.iterationId -cne
            [string]$Intent.subject.iterationId -or
        [string]$Snapshot.sourceCommit -cne
            [string]$Intent.subject.sourceCommit) {
        throw 'coverage-v2-discussions-ambiguous'
    }
    $atAnchor = [Collections.Generic.List[object]]::new()
    foreach ($thread in $Snapshot.threads) {
        if ($thread -isnot [Collections.IDictionary] -or
            $thread.comments -isnot [array] -or
            $thread.comments.Count -gt 200 -or
            $thread.anchor -isnot [Collections.IDictionary]) {
            throw 'coverage-v2-discussions-ambiguous'
        }
        foreach ($comment in $thread.comments) {
            if ($comment -isnot [Collections.IDictionary]) {
                throw 'coverage-v2-discussions-ambiguous'
            }
            if ([string]$comment.body -imatch
                '<\s*!\s*--\s*devpilot') {
                throw 'coverage-v2-marker-present-or-ambiguous'
            }
        }
        if ([string]$thread.anchor.path -ieq [string]$Intent.path -and
            [string]$thread.anchor.path -cne [string]$Intent.path) {
            throw 'coverage-v2-discussions-ambiguous'
        }
        if ([string]$thread.anchor.path -ceq [string]$Intent.path -and
            [string]$thread.anchor.line -ceq [string]$Intent.line) {
            [void]$atAnchor.Add($thread)
        }
    }
    if ($atAnchor.Count -gt 1) { throw 'coverage-v2-discussions-ambiguous' }
    if ($atAnchor.Count -eq 1) {
        $thread = $atAnchor[0]
        if ($thread.isDeleted -cne $false -or $thread.isOutdated -cne $false -or
            [string]$thread.status -cne 'active' -or
            [string]$thread.sourceCommit -cne
                [string]$Intent.subject.sourceCommit -or
            $thread.comments.Count -ne 1) {
            throw 'coverage-v2-discussions-ambiguous'
        }
        $comment = $thread.comments[0]
        Assert-CoverageV2Identity $comment.author $Human
        if ([string]$thread.contextState -cne 'current' -or
            [string]$comment.reviewerIdentityState -cne 'matched' -or
            $comment.isDeleted -cne $false -or
            [string]$comment.commentType -cne 'text' -or
            -not (Test-OwnerCoverageHumanAffirmation `
                    -CapabilityId ([string]$Intent.ruleId) `
                    -Body ([string]$comment.body))) {
            throw 'coverage-v2-human-ambiguous'
        }
        return 'humanCovered'
    }
    return 'wouldCreate'
}

function Invoke-CoverageV2CreateOnly {
    param([Collections.IDictionary]$Config, [Collections.IDictionary]$Intent,
        [Collections.IDictionary]$CurrentHead,
        [Collections.IDictionary]$CurrentBearer,
        [Collections.IDictionary]$Human,
        [Collections.IDictionary]$Snapshot,
        [Collections.IDictionary]$Ledger)
    if ($null -eq $Config -or $Config.enabled -isnot [bool] -or
        $Config.enabled -cne $true -or
        [string]$Config.mode -cne 'coverage-v2-create-only') {
        throw 'coverage-v2-writer-disabled'
    }
    [void](Get-CoverageV2OfflineDecision $Intent $CurrentHead `
            $CurrentBearer $Human $Snapshot $Ledger)
    # No trusted per-finding signer, same-bearer source verifier, or atomic durable
    # reservation/readback ledger is supplied by the PR191 read-only contracts.
    throw 'coverage-v2-intent-source-ledger-authority-unavailable'
}

Export-ModuleMember -Function @()
