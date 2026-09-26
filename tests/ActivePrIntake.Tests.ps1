#requires -Version 7.0
BeforeAll {
    $repo = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $repo 'src\DevPilot.ActivePrIntake\DevPilot.ActivePrIntake.psd1') -Force
    $template = Get-Content (Join-Path $repo 'samples\active-pr-intake.config.json') -Raw |
        ConvertFrom-Json -AsHashtable
    $script:roots = [Collections.Generic.List[string]]::new()
    function New-IntakeCase {
        param([int]$Count = 7, [int]$PageSize = 3, [int]$MaxHeads = 7)
        $config = Get-Content (Join-Path $repo 'samples\active-pr-intake.config.json') -Raw |
            ConvertFrom-Json -AsHashtable
        $config.enabled = $true
        $config.limits.pageSize = $PageSize
        $config.limits.maxHeadsPerRun = $MaxHeads
        $config.limits.maxReads = 30000
        $root = Join-Path $env:USERPROFILE (
            '.copilot\intake-pester-' + [guid]::NewGuid().ToString('N'))
        $script:roots.Add($root)
        $rows = @(
            for ($i = 1; $i -le $Count; $i++) {
                @{ pullRequestId = $i; status = 'active'; isDraft = $false
                    targetRef = 'refs/heads/master' }
            }
        )
        $state = @{ rows = $rows; calls = [Collections.Generic.List[string]]::new()
            drift = 0; failPage = 0; failHead = 0
            reorder = $false; duplicate = $false
            noTotal = $false
            comments = @(); changeLines = 3; headVisits = @{}
            sourceContent = $null
            iteration = 1; commit = 'a' * 40
            headStatus = @{}; headTarget = @{}; headDraft = @{} }
        $provider = {
            param($op, $request)
            $state.calls.Add("$op`:$($request.pullRequestId)") | Out-Null
            switch ($op) {
                Identity {
                    return @{ id = $config.expectedAccount.id
                        uniqueName = $config.expectedAccount.uniqueName }
                }
                ListPage {
                    if ($state.failPage -eq $request.skip + 1) { throw 'private provider diagnostic' }
                    $items = @($state.rows | Select-Object -Skip $request.skip -First $request.top)
                    if ($state.reorder -and $request.pass -eq 2) {
                        $items = @($state.rows[($state.rows.Count - 1)..0] |
                            Select-Object -Skip $request.skip -First $request.top)
                    }
                    if ($state.duplicate -and $request.skip -eq 3) {
                        $items[0] = $state.rows[2]
                    }
                    $page = @{ items = $items; count = $items.Count }
                    if (-not $state.noTotal) { $page.totalCount = $state.rows.Count }
                    return $page
                }
                Head {
                    $id = [int]$request.pullRequestId
                    if ($state.failHead -eq $id) { throw 'inaccessible secret head' }
                    if (-not $state.headVisits.ContainsKey($id)) { $state.headVisits[$id] = 0 }
                    $state.headVisits[$id]++
                    $source = if ($state.drift -eq $id -and
                        $state.headVisits[$id] -gt 1) { 'c' * 40 } else { $state.commit }
                    return @{ pullRequestId = $id
                        repositoryId = $config.repositoryId; projectId = $config.projectId
                        status = if ($state.headStatus.ContainsKey($id)) {
                            $state.headStatus[$id]
                        } else { $state.rows[$id - 1].status }
                        isDraft = if ($state.headDraft.ContainsKey($id)) {
                            $state.headDraft[$id]
                        } else { $state.rows[$id - 1].isDraft }
                        sourceRef = 'refs/heads/feature'
                        targetRef = if ($state.headTarget.ContainsKey($id)) {
                            $state.headTarget[$id]
                        } else { $state.rows[$id - 1].targetRef }
                        sourceCommit = $source; targetCommit = 'b' * 40
                        iterationId = $state.iteration }
                }
                Changes {
                    return @{ changedFiles = 2; changedLines = $state.changeLines
                        sourceContent = $state.sourceContent }
                }
                Discussions {
                    return @{ threads = $state.comments; count = $state.comments.Count }
                }
                default { throw 'A write or unknown operation was attempted' }
            }
        }.GetNewClosure()
        return @{ config = $config; provider = $provider; state = $state; root = $root }
    }
    function Invoke-IntakeCase {
        param($Case)
        Invoke-ActivePrIntake -Config $Case.config -Provider $Case.provider `
            -StateRoot $Case.root -RepositoryRoot $repo -Run
    }
}
AfterAll {
    foreach ($root in $script:roots) {
        if (Test-Path -LiteralPath $root) {
            Remove-Item -LiteralPath $root -Recurse -Force
        }
    }
}
Describe 'Active PR read-only intake' {
    It 'enumerates 347 non-draft heads from 574 active with 227 drafts across 100+ pages' {
        $c = New-IntakeCase -Count 574 -PageSize 3 -MaxHeads 5
        for ($i = 0; $i -lt 227; $i++) { $c.state.rows[$i].isDraft = $true }
        $c.state.rows[230].targetRef = 'refs/heads/release'
        $e = Invoke-IntakeCase $c
        $e.populationKnown | Should -BeTrue
        $e.kind | Should -Be 'active-pr-intake-cohort'
        $e.generation | Should -Match '^[a-f0-9]{32}$'
        $e.observedUtc | Should -Match 'Z$'
        $e.inventory.state | Should -Be 'complete'
        $e.inventory.active | Should -Be 574
        $e.inventory.draft | Should -Be 227
        $e.inventory.nonDraft | Should -Be 347
        $e.inventory.discovered | Should -Be 347
        $e.inventory.eligible | Should -Be 346
        $e.inventory.excludedOtherTargets | Should -Be 1
        $e.heads.Count | Should -Be 347
        @($e.heads | Where-Object pullRequestId -le 227).Count | Should -Be 0
        $e.rules[0].capabilityId | Should -Be $c.config.rules[0].capability
        $e.rules[0].discovered | Should -Be 347
        $e.rules[0].eligible | Should -Be 346
        $e.rules[0].evaluated | Should -Be 0
        $e.rules[0].pending | Should -Be 346
        $e.gaps | Should -Contain 'pending-rules'
        $e.counts.discovered | Should -Be 347
        $e.pages.first | Should -Be 192
        $e.pages.second | Should -Be 192
        $e.denominators.active | Should -Be 574
        $e.denominators.eligible | Should -Be 346
        $e.denominators.byTargetRef['refs/heads/release'].nonDraft | Should -Be 1
        $e.counts.skipped | Should -Be 1
        $e.counts.deferred | Should -Be 341
        $e.counts.evaluated | Should -Be 0
        $e.heads[3].reasonCode | Should -Be 'target-out-of-policy'
        @($c.state.calls | Where-Object { $_ -match 'write|post|patch' }).Count |
            Should -Be 0
    }
    It 'reconciles reorderings without assuming page order or dropping the old tail' {
        $c = New-IntakeCase -Count 7
        $c.state.reorder = $true
        $e = Invoke-IntakeCase $c
        $e.counts.discovered | Should -Be 7
        $e.populationKnown | Should -BeTrue
        @($e.heads.pullRequestId) | Should -Be @(1,2,3,4,5,6,7)
        $c = New-IntakeCase -Count 7
        $c.state.noTotal = $true
        $e = Invoke-IntakeCase $c
        $e.counts.discovered | Should -Be 7
        $e.pages.first | Should -Be 3
    }
    It 'fails closed for duplicate shifting, inaccessible pages and page or PR caps' {
        $c = New-IntakeCase -Count 7
        $c.state.duplicate = $true
        $e = Invoke-IntakeCase $c
        $e.populationKnown | Should -BeFalse
        $e.inventory.state | Should -Be 'unknown'
        $e.inventory.discovered | Should -BeNullOrEmpty
        $e.inventory.eligible | Should -BeNullOrEmpty
        $e.inventory.excludedOtherTargets | Should -BeNullOrEmpty
        $e.inventory.byTargetRef | Should -BeNullOrEmpty
        $e.gaps | Should -Contain 'inventory-unknown'
        $e.rules[0].discovered | Should -BeNullOrEmpty
        $e.rules[0].gaps | Should -Contain 'inventory-unknown'
        $e.reasonCodes | Should -Contain 'missing-page'
        $c = New-IntakeCase -Count 7
        $c.state.failPage = 4
        $e = Invoke-IntakeCase $c
        $e.reasonCodes | Should -Contain 'page-inaccessible'
        ($e | ConvertTo-Json -Depth 32) | Should -Not -Match 'private provider diagnostic'
        $c = New-IntakeCase -Count 7
        $c.config.limits.maxPages = 2
        (Invoke-IntakeCase $c).reasonCodes | Should -Contain 'page-budget'
        $c = New-IntakeCase -Count 7
        $c.config.limits.maxPullRequests = 6
        (Invoke-IntakeCase $c).reasonCodes | Should -Contain 'pr-budget'
        $c = New-IntakeCase -Count 7
        $c.config.limits.maxReads = 2
        (Invoke-IntakeCase $c).reasonCodes | Should -Contain 'read-budget'
    }
    It 'rotates fairly across long-tail PRs and verifies historical heads afresh' {
        $c = New-IntakeCase -Count 7 -MaxHeads 2
        $visited = [Collections.Generic.HashSet[int]]::new()
        $firstGeneration = $null
        $firstBytes = $null
        for ($i = 0; $i -lt 4; $i++) {
            $e = Invoke-IntakeCase $c
            if ($i -eq 0) {
                $firstGeneration = Join-Path (Join-Path $c.root 'active-pr-intake-v1') `
                    $e.generationFile
                $firstBytes = [IO.File]::ReadAllBytes($firstGeneration)
            }
            foreach ($h in @($e.heads | Where-Object { $_.declaration })) {
                [void]$visited.Add($h.pullRequestId)
            }
        }
        $visited.Count | Should -Be 7
        $e.generationOrdinal | Should -Be 4
        (Get-ChildItem (Join-Path $c.root 'active-pr-intake-v1\generations') `
                -Filter '*.json').Count | Should -Be 4
        [Convert]::ToHexString([IO.File]::ReadAllBytes($firstGeneration)) |
            Should -Be ([Convert]::ToHexString($firstBytes))
        (Get-Content (Join-Path $c.root 'active-pr-intake-v1\cohort.json') -Raw) |
            Should -Be (Get-Content (
                    Join-Path (Join-Path $c.root 'active-pr-intake-v1') `
                        $e.generationFile) -Raw)
        $c.state.headVisits[1] | Should -BeGreaterThan 1
        $e.cursor.nextPullRequestId | Should -Be 2
    }
    It 'marks changed or inaccessible heads unknown, never evaluated' {
        $c = New-IntakeCase -Count 3
        $c.state.drift = 1
        $e = Invoke-IntakeCase $c
        $e.heads[0].state | Should -Be 'unknown'
        $e.heads[0].reasonCode | Should -Be 'head-drift'
        $e.gapCounts.drift | Should -Be 1
        $e.gaps | Should -Contain 'head-drift'
        $e.counts.evaluated | Should -Be 0
        $c = New-IntakeCase -Count 3
        $c.state.changeLines = $null
        $e = Invoke-IntakeCase $c
        $e.heads[0].reasonCode | Should -Be 'line-count-unavailable'
        $e.gapCounts.unknownHeads | Should -Be 3
        $e.unmetCapabilities | Should -Contain 'changed-line-counts'
        $e.gaps | Should -Contain 'line-count-unavailable'
        $c = New-IntakeCase -Count 3
        $c.state.failHead = 2
        $e = Invoke-IntakeCase $c
        $e.heads[1].state | Should -Be 'unknown'
        $e.heads[1].reasonCode | Should -Be 'provider-inaccessible'
        ($e | ConvertTo-Json -Depth 32) | Should -Not -Match 'inaccessible secret head'
    }
    It 'quarantines closed, retargeted and newly drafted heads as snapshot drift' {
        $c = New-IntakeCase -Count 3
        $c.state.headStatus[1] = 'completed'
        $c.state.headTarget[2] = 'refs/heads/release'
        $c.state.headDraft[3] = $true
        $e = Invoke-IntakeCase $c
        $e.denominators.eligible | Should -Be 3
        $e.counts.skipped | Should -Be 0
        $e.counts.error | Should -Be 3
        $e.gapCounts.drift | Should -Be 3
        $e.counts.evaluated | Should -Be 0
        @($e.heads | Where-Object reasonCode -eq 'head-left-policy-drift').Count |
            Should -Be 3
        @($e.heads | Where-Object status -eq 'unknown').Count | Should -Be 3
        $e.heads[1].targetRef | Should -Be 'refs/heads/release'
        @($c.state.calls | Where-Object { $_ -like 'Changes*' }).Count |
            Should -Be 0
    }
    It 'deduplicates human and marked automation but treats unmarked same account as human' {
        $c = New-IntakeCase -Count 1
        $c.state.sourceContent = 'private source sentinel'
        $account = @{ id = $c.config.expectedAccount.id
            descriptor = $c.config.expectedAccount.descriptor
            uniqueName = $c.config.expectedAccount.uniqueName }
        $c.state.comments = @(
            @{ id = 1; comments = @(
                    @{ id = 1; author = $account; commentType = 'text'; content = 'plain human' },
                    @{ id = 1; author = $account; commentType = 'text'; content = 'plain human' },
                    @{ id = 2; author = $account; commentType = 'text'
                        content = '[DevPilot-Automation:v1] result' }
                ) }
        )
        $e = Invoke-IntakeCase $c
        $e.heads[0].reasonCode | Should -Be 'rules-incomplete'
        $e.heads[0].discussion.human | Should -Be 1
        $e.heads[0].discussion.automation | Should -Be 1
        (Get-Content (Join-Path $c.root 'active-pr-intake-v1\cohort.json') -Raw) |
            Should -Not -Match 'plain human|result|private source sentinel'
        $c.state.comments[0].threadContext = @{ filePath = '/src/X.cs'
            rightFileStart = @{ line = 5 } }
        $e = Invoke-IntakeCase $c
        $e.heads[0].discussion.ambiguous | Should -Be 2
        $e.heads[0].rules[0].state | Should -Be 'unknown'
        $c.state.comments[0].threadContext.rightFileEnd = @{ line = 5 }
        $c.state.comments[0].pullRequestThreadContext = @{
            changeTrackingId = 1
            iterationContext = @{
                firstComparingIteration = 1
                secondComparingIteration = 1
            }
        }
        $current = Invoke-IntakeCase $c
        $current.heads[0].discussion.currentAnchored | Should -Be 2
        $current.heads[0].discussion.human | Should -Be 1
        $current.heads[0].discussion.automation | Should -Be 1
        $current.heads[0].discussion.ambiguous | Should -Be 0
        $c.state.comments[0].threadContext.rightFileEnd.line = 6
        $shifted = Invoke-IntakeCase $c
        $shifted.heads[0].discussion.ambiguous | Should -Be 2
        $shifted.heads[0].discussion.human | Should -Be 0
        $c.state.comments[0].threadContext.rightFileEnd.line = 5
        $c.state.iteration = 2
        $outdated = Invoke-IntakeCase $c
        $outdated.heads[0].discussion.outdated | Should -Be 2
        $outdated.heads[0].discussion.ambiguous | Should -Be 2
        $outdated.heads[0].rules[0].state | Should -Be 'unknown'
        $outdated.heads[0].discussion.human | Should -Be 0
        $outdated.heads[0].discussion.automation | Should -Be 0
    }
    It 'registers generic capabilities without accepting evaluator callbacks or completion claims' {
        $c = New-IntakeCase -Count 1
        $pending = Invoke-IntakeCase $c
        $pending.heads[0].rules[0].state | Should -Be 'pending'
        $pending.rules[0].evaluated | Should -Be 0
        $pending.heads[0].rules[0].observationDigest | Should -BeNullOrEmpty
        $pending.heads[0].rules[0].capabilityId |
            Should -Be $c.config.rules[0].capability
        $identity = $pending.heads[0].rules[0].identityDigest
        $again = Invoke-IntakeCase $c
        $again.heads[0].rules[0].identityDigest | Should -Be $identity
        { Invoke-ActivePrIntake -Config $c.config -Provider $c.provider `
                -StateRoot $c.root -RepositoryRoot $repo -Run `
                -Evaluators @{ fake = { throw 'must not run' } } } |
            Should -Throw
        $c.config.rules[0].id = 'different-generic-rule'
        (Invoke-IntakeCase $c).heads[0].rules[0].identityDigest |
            Should -Not -Be $identity
    }
    It 'never promotes iteration-17 metadata or a navigation GET to iteration 21 evaluation' {
        $c = New-IntakeCase -Count 1
        $c.config.rules[0].id = 'public-response-sanitization-v1'
        $c.config.rules[0].capability = 'public-response-sanitization-v1'
        $c.state.iteration = 17
        $old = Invoke-IntakeCase $c
        $old.counts.evaluated | Should -Be 0
        $old.writerEligible | Should -BeFalse
        $old.autoPost | Should -BeFalse
        $legacy = Get-Content (Join-Path $c.root 'active-pr-intake-v1\cohort.json') `
            -Raw | ConvertFrom-Json -AsHashtable
        $legacy.heads[0].rules[0].state = 'evaluated'
        $legacy.heads[0].rules[0].status = 'evaluated'
        $legacy.heads[0].rules[0].observationDigest = 'd' * 64
        $legacyJson = ConvertTo-Json -InputObject $legacy -Depth 32
        $oldPath = Join-Path (Join-Path $c.root 'active-pr-intake-v1') `
            $old.generationFile
        [IO.File]::WriteAllText($oldPath, $legacyJson)
        [IO.File]::WriteAllText(
            (Join-Path $c.root 'active-pr-intake-v1\cohort.json'), $legacyJson)
        $c.state.iteration = 21
        $current = Invoke-IntakeCase $c
        $current.counts.evaluated | Should -Be 0
        $current.heads[0].declaration.iterationId | Should -Be 21
        $current.heads[0].rules[0].state | Should -Be 'pending'
        $current.heads[0].rules[0].reasonCode | Should -Be 'stale-observation'
        $current.heads[0].rules[0].priorObservation.state | Should -Be 'stale'
        $current.gaps | Should -Contain 'stale-observation'
        $current.heads[0].rules[0].identityDigest |
            Should -Not -Be $old.heads[0].rules[0].identityDigest
        $c.state.sourceContent = 'PR177 navigation GET/link is not evaluation'
        $nav = Invoke-IntakeCase $c
        $nav.rules[0].evaluated | Should -Be 0
        $nav.heads[0].rules[0].status | Should -Be 'pending'
        $nav.heads[0].rules[0].writerEligible | Should -BeFalse
        (Get-Content (Join-Path $c.root 'active-pr-intake-v1\cohort.json') -Raw) |
            Should -Not -Match 'navigation GET/link'
    }
    It 'defaults off and refuses state inside the repository or a changed account' {
        $c = New-IntakeCase -Count 1
        $c.config.enabled = $false
        $e = Invoke-IntakeCase $c
        $e.state | Should -Be 'disabled'
        $e.readCount | Should -Be 0
        $c.config.enabled = $true
        $c.config.expectedAccount.id = '99999999-9999-9999-9999-999999999999'
        $c.provider = {         param($op,$request)
            if ($op -eq 'Identity') { return @{ id = '00000000-0000-0000-0000-000000000000'
                    uniqueName = 'other@example.invalid' } }
            throw 'should not enumerate'
        }
        $e = Invoke-IntakeCase $c
        $e.reasonCodes | Should -Contain 'account-mismatch'
        { Invoke-ActivePrIntake -Config $c.config -Provider $c.provider `
                -StateRoot (Join-Path $repo 'state') -RepositoryRoot $repo -Run } |
            Should -Throw
    }
    It 'refuses to advance a latest snapshot whose immutable generation was changed' {
        $c = New-IntakeCase -Count 1
        $old = Invoke-IntakeCase $c
        $generationPath = Join-Path (Join-Path $c.root 'active-pr-intake-v1') `
            $old.generationFile
        Set-Content -LiteralPath $generationPath -Value '{"tampered":true}'
        { Invoke-IntakeCase $c } | Should -Throw
        (Get-ChildItem (Join-Path $c.root 'active-pr-intake-v1\generations') `
                -Filter '*.json').Count | Should -Be 1
        $latest = Get-Content (Join-Path $c.root 'active-pr-intake-v1\cohort.json') `
            -Raw | ConvertFrom-Json
        $latest.generation | Should -Be $old.generation
    }
    It 'pins Azure CLI transport to GET, organization, project, repository and account' {
        $c = New-IntakeCase -Count 1
        $c.config.enabled = $false
        [void](Invoke-IntakeCase $c)
        $stub = Join-Path $c.root 'az-read-stub.ps1'
        $log = Join-Path $c.root 'az-requests.log'
        $env:ACTIVE_PR_INTAKE_TEST_LOG = $log
        try {
            @'
$CliArguments = $args
[IO.File]::AppendAllText($env:ACTIVE_PR_INTAKE_TEST_LOG, ($CliArguments -join '|') + "`n")
$global:LASTEXITCODE = 0
if ($CliArguments -contains 'connectionData') {
    '{"authenticatedUser":{"id":"33333333-3333-3333-3333-333333333333","uniqueName":"service@example.invalid"}}'
} elseif ($CliArguments -contains 'pullRequestIterations') {
    '{"value":[{"id":1,"sourceRefCommit":{"commitId":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"targetRefCommit":{"commitId":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}}]}'
} elseif ($CliArguments -contains 'pullRequestIterationChanges') {
    '{"changeEntries":[]}'
} elseif ($CliArguments -contains 'pullRequestThreads') {
    '{"value":[],"count":0}'
} elseif ($CliArguments -contains 'pullRequestId=1') {
    '{"pullRequestId":1,"status":"active","isDraft":false,"sourceRefName":"refs/heads/feature","targetRefName":"refs/heads/master","repository":{"id":"11111111-1111-1111-1111-111111111111","project":{"id":"22222222-2222-2222-2222-222222222222"}}}'
} else {
    '{"value":[{"pullRequestId":1,"status":"active","isDraft":false,"targetRefName":"refs/heads/master","repository":{"id":"11111111-1111-1111-1111-111111111111","project":{"id":"22222222-2222-2222-2222-222222222222"}}}],"count":1}'
}
'@ | Set-Content -LiteralPath $stub -Encoding utf8
            $transport = New-ActivePrAzureDevOpsProvider -Config $c.config -AzureCliPath $stub
            $identity = & $transport 'Identity' @{}
            $identity.uniqueName | Should -Be 'service@example.invalid'
            $page = & $transport 'ListPage' @{ pass = 1; skip = 0; top = 3 }
            $page.items[0].pullRequestId | Should -Be 1
            $requests = Get-Content -LiteralPath $log
            $requests.Count | Should -Be 2
            foreach ($request in $requests) {
                $request | Should -Match '\|--http-method\|GET\|'
                $request | Should -Match '\|--organization\|https://dev.azure.com/example-org\|'
                $request | Should -Not -Match 'POST|PATCH|PUT|DELETE|--in-file'
            }
            $requests[1] | Should -Match 'project=ExampleProject'
            $requests[1] | Should -Match 'repositoryId=11111111-1111-1111-1111-111111111111'
            $c.config.enabled = $true
            $liveShape = Invoke-ActivePrIntake -Config $c.config -Provider $transport `
                -StateRoot $c.root -RepositoryRoot $repo -Run
            $liveShape.inventory.discovered | Should -Be 1
            $liveShape.heads[0].reasonCode | Should -Be 'line-count-unavailable'
            $liveShape.heads[0].status | Should -Be 'unknown'
            $liveShape.rules[0].evaluated | Should -Be 0
            $liveShape.rules[0].error | Should -Be 1
            $liveShape.unmetCapabilities | Should -Contain 'changed-line-counts'
            foreach ($request in (Get-Content -LiteralPath $log)) {
                $request | Should -Match '\|--http-method\|GET\|'
            }
            if ($IsWindows) {
                $cmd = Join-Path $c.root 'az-read-stub.cmd'
                @'
@echo off
echo {"authenticatedUser":{"id":"33333333-3333-3333-3333-333333333333","uniqueName":"service@example.invalid"}}
'@ | Set-Content -LiteralPath $cmd -Encoding ascii
                $cmdTransport = New-ActivePrAzureDevOpsProvider -Config $c.config -AzureCliPath $cmd
                (& $cmdTransport 'Identity' @{ timeoutMilliseconds = 3000 }).id |
                    Should -Be '33333333-3333-3333-3333-333333333333'
            }
            $slowStub = Join-Path $c.root 'az-slow-stub.ps1'
            'Start-Sleep -Seconds 5' | Set-Content -LiteralPath $slowStub -Encoding utf8
            $slowTransport = New-ActivePrAzureDevOpsProvider -Config $c.config `
                -AzureCliPath $slowStub
            $watch = [Diagnostics.Stopwatch]::StartNew()
            { & $slowTransport 'Identity' @{ timeoutMilliseconds = 250 } } |
                Should -Throw 'time-budget'
            $watch.Elapsed.TotalSeconds | Should -BeLessThan 4
            $largeStub = Join-Path $c.root 'az-large-stub.ps1'
            '[Console]::Out.Write((''x'' * 17000000))' |
                Set-Content -LiteralPath $largeStub -Encoding utf8
            $largeTransport = New-ActivePrAzureDevOpsProvider -Config $c.config `
                -AzureCliPath $largeStub
            { & $largeTransport 'Identity' @{ timeoutMilliseconds = 10000 } } |
                Should -Throw 'read-budget'
        }
        finally { Remove-Item Env:\ACTIVE_PR_INTAKE_TEST_LOG -ErrorAction SilentlyContinue }
    }
}
