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
            noTotal = $false; listCap = 0
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
                        descriptor = $config.expectedAccount.descriptor
                        uniqueName = $config.expectedAccount.uniqueName }
                }
                ListPage {
                    if ($state.failPage -eq $request.skip + 1) { throw 'private provider diagnostic' }
                    $top = if ($state.listCap -gt 0) {
                        [Math]::Min($request.top, $state.listCap)
                    } else { $request.top }
                    $items = @($state.rows | Select-Object -Skip $request.skip -First $top)
                    if ($state.reorder -and $request.pass -eq 2) {
                        $items = @($state.rows[($state.rows.Count - 1)..0] |
                            Select-Object -Skip $request.skip -First $top)
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
    function Save-IntakeCredentialEnvironment {
        $environment = [Environment]::GetEnvironmentVariables(
            [EnvironmentVariableTarget]::Process)
        return [ordered]@{
            patPresent = $environment.Contains('AZURE_DEVOPS_EXT_PAT')
            patValue = [Environment]::GetEnvironmentVariable(
                'AZURE_DEVOPS_EXT_PAT',
                [EnvironmentVariableTarget]::Process)
            systemPresent =
                $environment.Contains('SYSTEM_ACCESSTOKEN')
            systemValue = [Environment]::GetEnvironmentVariable(
                'SYSTEM_ACCESSTOKEN',
                [EnvironmentVariableTarget]::Process)
        }
    }
    function Set-IntakeCredentialSentinels {
        $snapshot = Save-IntakeCredentialEnvironment
        [Environment]::SetEnvironmentVariable(
            'AZURE_DEVOPS_EXT_PAT',
            'must-not-reach-child',
            [EnvironmentVariableTarget]::Process)
        [Environment]::SetEnvironmentVariable(
            'SYSTEM_ACCESSTOKEN',
            'must-not-reach-child',
            [EnvironmentVariableTarget]::Process)
        return $snapshot
    }
    function Restore-IntakeCredentialEnvironment {
        param([Collections.IDictionary]$Snapshot)
        [Environment]::SetEnvironmentVariable(
            'AZURE_DEVOPS_EXT_PAT',
            $(if ([bool]$Snapshot.patPresent) {
                [string]$Snapshot.patValue
            } else { $null }),
            [EnvironmentVariableTarget]::Process)
        [Environment]::SetEnvironmentVariable(
            'SYSTEM_ACCESSTOKEN',
            $(if ([bool]$Snapshot.systemPresent) {
                [string]$Snapshot.systemValue
            } else { $null }),
            [EnvironmentVariableTarget]::Process)
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
        $e.inventory.gaps | Should -Contain 'no-atomic-snapshot-token'
        $e.gaps | Should -Contain 'no-atomic-snapshot-token'
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
        $e.pages.first | Should -Be 4
        $c = New-IntakeCase -Count 7
        $c.state.noTotal = $true
        $c.state.listCap = 2
        $e = Invoke-IntakeCase $c
        $e.populationKnown | Should -BeTrue
        $e.counts.discovered | Should -Be 7
        $e.pages.first | Should -Be 5
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
    It 'is non-mutating without -Run and when disabled, including existing cohorts' {
        $c = New-IntakeCase -Count 1
        $c.config.enabled = $true
        $dry = Invoke-ActivePrIntake -Config $c.config -Provider $c.provider `
            -StateRoot $c.root -RepositoryRoot $repo
        $dry.state | Should -Be 'disabled'
        $dry.generation | Should -BeNullOrEmpty
        $dry.generationFile | Should -BeNullOrEmpty
        $dry.inventory.discovered | Should -BeNullOrEmpty
        $dry.readCount | Should -Be 0
        (Test-Path -LiteralPath $c.root) | Should -BeFalse
        $scriptPath = Join-Path $repo 'tools\Invoke-ActivePrIntake.ps1'
        $samplePath = Join-Path $repo 'samples\active-pr-intake.config.json'
        $wrapper = & pwsh -NoProfile -NonInteractive -File $scriptPath `
            -ConfigPath $samplePath -StateRoot $c.root `
            -AzureCliPath 'no-ado-cli-required-for-disabled-summary' |
            ConvertFrom-Json -AsHashtable
        $LASTEXITCODE | Should -Be 0
        $wrapper.state | Should -Be 'disabled'
        $wrapper.generation | Should -BeNullOrEmpty
        (Test-Path -LiteralPath $c.root) | Should -BeFalse
        $active = Invoke-IntakeCase $c
        $path = Join-Path $c.root 'active-pr-intake-v1\cohort.json'
        $latestBytes = [IO.File]::ReadAllBytes($path)
        $generationPath = Join-Path (Join-Path $c.root 'active-pr-intake-v1') `
            $active.generationFile
        $immutableBytes = [IO.File]::ReadAllBytes($generationPath)
        $beforeFiles = @(
            Get-ChildItem -LiteralPath (Join-Path $c.root 'active-pr-intake-v1') `
                -Recurse -File | ForEach-Object FullName | Sort-Object
        )
        $c.config.enabled = $false
        $e = Invoke-IntakeCase $c
        $e.state | Should -Be 'disabled'
        $e.readCount | Should -Be 0
        $e.generation | Should -BeNullOrEmpty
        $c.config.enabled = $true
        $again = Invoke-ActivePrIntake -Config $c.config -Provider $c.provider `
            -StateRoot $c.root -RepositoryRoot $repo
        $again.state | Should -Be 'disabled'
        [Convert]::ToHexString([IO.File]::ReadAllBytes($path)) |
            Should -Be ([Convert]::ToHexString($latestBytes))
        [Convert]::ToHexString([IO.File]::ReadAllBytes($generationPath)) |
            Should -Be ([Convert]::ToHexString($immutableBytes))
        @(Get-ChildItem -LiteralPath (Join-Path $c.root 'active-pr-intake-v1') `
                -Recurse -File | ForEach-Object FullName | Sort-Object) |
            Should -Be $beforeFiles
        $c = New-IntakeCase -Count 1
        $c.config.enabled = $false
        (Invoke-IntakeCase $c).state | Should -Be 'disabled'
        (Test-Path -LiteralPath $c.root) | Should -BeFalse
    }
    It 'refuses state inside the repository or a changed account' {
        $c = New-IntakeCase -Count 1
        $c.config.enabled = $true
        $c.config.expectedAccount.id = '99999999-9999-9999-9999-999999999999'
        $c.provider = {         param($op,$request)
            if ($op -eq 'Identity') { return @{ id = '00000000-0000-0000-0000-000000000000'
                    descriptor = 'aad.other'
                    uniqueName = 'other@example.invalid' } }
            throw 'should not enumerate'
        }
        $e = Invoke-IntakeCase $c
        $e.reasonCodes | Should -Contain 'account-mismatch'
        { Invoke-ActivePrIntake -Config $c.config -Provider $c.provider `
                -StateRoot (Join-Path $repo 'state') -RepositoryRoot $repo -Run } |
            Should -Throw
        { Invoke-ActivePrIntake -Config $c.config -Provider $c.provider `
                -StateRoot (Join-Path $repo 'state') -RepositoryRoot $repo } |
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
    It 'pages server-capped ADO iteration changes to an empty terminator or fails closed' {
        $c = New-IntakeCase -Count 1
        New-Item -ItemType Directory -Path $c.root -Force | Out-Null
        $stub = Join-Path $c.root 'az-paged-changes.ps1'
        $log = Join-Path $c.root 'az-change-skips.log'
        @'
$skipArgument = @($args | Where-Object { $_.StartsWith('$skip=') })
if ($skipArgument.Count -ne 1) { exit 5 }
$skip = [int]$skipArgument[0].Substring(6)
[IO.File]::AppendAllText($env:ACTIVE_PR_INTAKE_CHANGE_LOG, "$skip`n")
$ids = if ($skip -ge 110) { @() }
elseif ($env:ACTIVE_PR_INTAKE_CHANGE_MODE -eq 'duplicate' -and $skip -gt 0) {
    @(1..37)
}
else { @(($skip + 1)..([Math]::Min($skip + 37, 110))) }
$response = @{
    changeEntries = @($ids | ForEach-Object {
        @{
            changeTrackingId = $_
            changeType = 'delete'
            item = @{ path = "/deleted$_.cs" }
        }
    })
    count = $ids.Count
    nextSkip = if ($ids.Count -eq 0) { 0 } else { $skip + $ids.Count }
}
if ($env:ACTIVE_PR_INTAKE_CHANGE_MODE -eq 'wrong-total') {
    $response.totalCount = 111
}
$response | ConvertTo-Json -Depth 8 -Compress
'@ | Set-Content -LiteralPath $stub -Encoding utf8
        $env:ACTIVE_PR_INTAKE_CHANGE_LOG = $log
        try {
            $provider = New-ActivePrAzureDevOpsProvider -Config $c.config `
                -AzureCliPath $stub
            $changes = & $provider 'Changes' @{
                pullRequestId = 1; iterationId = 1
                sourceCommit = 'a' * 40; targetCommit = 'b' * 40
                timeoutMilliseconds = 15000
            }
            $changes.changedFiles | Should -Be 110
            $changes.changedLines | Should -Be 0
            @($changes.entries) | Should -HaveCount 110
            @(Get-Content -LiteralPath $log) | Should -Be @('0', '37', '74', '110')
            $env:ACTIVE_PR_INTAKE_CHANGE_MODE = 'duplicate'
            { & $provider 'Changes' @{
                    pullRequestId = 1; iterationId = 1
                    sourceCommit = 'a' * 40; targetCommit = 'b' * 40
                    timeoutMilliseconds = 15000
                } } | Should -Throw 'change-list-truncated'
            $env:ACTIVE_PR_INTAKE_CHANGE_MODE = 'wrong-total'
            { & $provider 'Changes' @{
                    pullRequestId = 1; iterationId = 1
                    sourceCommit = 'a' * 40; targetCommit = 'b' * 40
                    timeoutMilliseconds = 15000
                } } | Should -Throw 'change-list-truncated'
            $env:ACTIVE_PR_INTAKE_CHANGE_MODE = ''
            $c.config.limits.maxPages = 3
            { & $provider 'Changes' @{
                    pullRequestId = 1; iterationId = 1
                    sourceCommit = 'a' * 40; targetCommit = 'b' * 40
                    timeoutMilliseconds = 15000
                } } | Should -Throw 'change-page-budget'
            $c.config.limits.maxPages = 10
            $c.config.limits.maxChangedFiles = 109
            $capped = New-ActivePrAzureDevOpsProvider -Config $c.config `
                -AzureCliPath $stub
            { & $capped 'Changes' @{
                    pullRequestId = 1; iterationId = 1
                    sourceCommit = 'a' * 40; targetCommit = 'b' * 40
                    timeoutMilliseconds = 15000
                } } | Should -Throw 'file-budget'
            $c.config.limits.maxChangedFiles = 200
            $c.config.limits.maxReads = 2
            $readLimited = New-ActivePrAzureDevOpsProvider -Config $c.config `
                -AzureCliPath $stub
            { & $readLimited 'Changes' @{
                    pullRequestId = 1; iterationId = 1
                    sourceCommit = 'a' * 40; targetCommit = 'b' * 40
                    timeoutMilliseconds = 15000
                } } | Should -Throw 'read-budget'
        }
        finally {
            Remove-Item Env:\ACTIVE_PR_INTAKE_CHANGE_LOG `
                -ErrorAction SilentlyContinue
            Remove-Item Env:\ACTIVE_PR_INTAKE_CHANGE_MODE `
                -ErrorAction SilentlyContinue
        }
    }
    It 'keeps a modified file unknown when required <Side> Item content is <Shape>' `
        -TestCases @(
            @{ Side = 'source'; Shape = 'missing' }
            @{ Side = 'source'; Shape = 'null' }
            @{ Side = 'source'; Shape = 'non-string' }
            @{ Side = 'target'; Shape = 'missing' }
            @{ Side = 'target'; Shape = 'null' }
            @{ Side = 'target'; Shape = 'non-string' }
        ) {
        param($Side, $Shape)
        $c = New-IntakeCase -Count 1
        New-Item -ItemType Directory -Path $c.root -Force | Out-Null
        $stub = Join-Path $c.root 'az-missing-target-content.ps1'
        $log = Join-Path $c.root 'item-requests.log'
        $env:ACTIVE_PR_INTAKE_ITEM_SIDE = $Side
        $env:ACTIVE_PR_INTAKE_ITEM_SHAPE = $Shape
        $env:ACTIVE_PR_INTAKE_ITEM_LOG = $log
        @'
$arguments = $args
if ($arguments -contains 'pullRequestIterationChanges') {
    if ($arguments -contains '$skip=1') {
        '{"changeEntries":[],"count":0}'
    }
    else {
        '{"changeEntries":[{"changeTrackingId":1,"changeType":"edit","item":{"path":"/tests/Checks.cs"}}],"count":1,"nextSkip":1}'
    }
}
elseif ($arguments -contains 'items') {
    [IO.File]::AppendAllText(
        $env:ACTIVE_PR_INTAKE_ITEM_LOG, ($arguments -join '|') + "`n")
    $side = if ($arguments -contains 'versionDescriptor.version=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa') {
        'source'
    }
    else { 'target' }
    if ($side -eq $env:ACTIVE_PR_INTAKE_ITEM_SIDE) {
        switch ($env:ACTIVE_PR_INTAKE_ITEM_SHAPE) {
            'missing' { '{"contentMetadata":{"contentType":"text/plain"}}' }
            'null' { '{"content":null,"contentMetadata":{"contentType":"text/plain"}}' }
            'non-string' { '{"content":{"value":"not text"},"contentMetadata":{"contentType":"text/plain"}}' }
        }
    }
    else {
        '{"content":"using Microsoft.VisualStudio.TestTools.UnitTesting;\n[TestClass] class Checks { [TestMethod] void Verify() { Assert.AreEqual(0, value); } }","contentMetadata":{"contentType":"text/plain"}}'
    }
}
else {
    exit 7
}
'@ | Set-Content -LiteralPath $stub -Encoding utf8
        try {
            $transport = New-ActivePrAzureDevOpsProvider `
                -Config $c.config -AzureCliPath $stub
            $baseProvider = $c.provider
            $provider = {
                param($operation, $request)
                if ($operation -ceq 'Changes') {
                    return & $transport $operation $request
                }
                return & $baseProvider $operation $request
            }.GetNewClosure()
            $result = Invoke-ActivePrIntake `
                -Config $c.config -Provider $provider `
                -StateRoot $c.root -RepositoryRoot $repo -Run

            $result.heads[0].state | Should -BeExactly 'unknown'
            $result.heads[0].reasonCode |
                Should -BeExactly 'item-content-unavailable'
            $result.counts.evaluated | Should -Be 0
            $result.rules[0].evaluated | Should -Be 0
            $requests = @(Get-Content -LiteralPath $log)
            $requests.Count | Should -BeGreaterOrEqual 1
            foreach ($request in $requests) {
                $request | Should -Match 'includeContent=true'
                $request | Should -Match 'includeContentMetadata=true'
            }
        }
        finally {
            Remove-Item Env:\ACTIVE_PR_INTAKE_ITEM_SIDE,
                Env:\ACTIVE_PR_INTAKE_ITEM_SHAPE,
                Env:\ACTIVE_PR_INTAKE_ITEM_LOG -ErrorAction SilentlyContinue
        }
    }
    It 'accepts explicit empty Item content for <ChangeType> without inventing revisions' `
        -TestCases @(
            @{ ChangeType = 'add'; ExpectedLines = 1; ExpectedItems = 1 }
            @{ ChangeType = 'edit'; ExpectedLines = 1; ExpectedItems = 2 }
            @{ ChangeType = 'delete'; ExpectedLines = 0; ExpectedItems = 0 }
        ) {
        param($ChangeType, $ExpectedLines, $ExpectedItems)
        $c = New-IntakeCase -Count 1
        New-Item -ItemType Directory -Path $c.root -Force | Out-Null
        $stub = Join-Path $c.root 'az-explicit-empty-content.ps1'
        $log = Join-Path $c.root 'empty-item-requests.log'
        $env:ACTIVE_PR_INTAKE_EMPTY_CHANGE = $ChangeType
        $env:ACTIVE_PR_INTAKE_EMPTY_LOG = $log
        @'
$arguments = $args
if ($arguments -contains 'pullRequestIterationChanges') {
    if ($arguments -contains '$skip=1') {
        '{"changeEntries":[],"count":0}'
    }
    else {
        @{
            changeEntries = @(@{
                changeTrackingId = 1
                changeType = $env:ACTIVE_PR_INTAKE_EMPTY_CHANGE
                item = @{ path = '/tests/Empty.cs' }
            })
            count = 1
            nextSkip = 1
        } | ConvertTo-Json -Depth 8 -Compress
    }
}
elseif ($arguments -contains 'items') {
    [IO.File]::AppendAllText(
        $env:ACTIVE_PR_INTAKE_EMPTY_LOG, ($arguments -join '|') + "`n")
    if ($arguments -contains 'versionDescriptor.version=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' -and
        $env:ACTIVE_PR_INTAKE_EMPTY_CHANGE -eq 'edit') {
        '{"content":"x","contentMetadata":{"contentType":"text/plain"}}'
    }
    else {
        '{"content":"","contentMetadata":{"contentType":"text/plain"}}'
    }
}
else {
    exit 7
}
'@ | Set-Content -LiteralPath $stub -Encoding utf8
        try {
            $transport = New-ActivePrAzureDevOpsProvider `
                -Config $c.config -AzureCliPath $stub
            $changes = & $transport 'Changes' @{
                pullRequestId = 1
                iterationId = 1
                sourceCommit = 'a' * 40
                targetCommit = 'b' * 40
                timeoutMilliseconds = 15000
            }
            $changes.changedFiles | Should -Be 1
            $changes.changedLines | Should -Be $ExpectedLines
            @($changes.entries) | Should -HaveCount 1
            $changes.entries[0].state | Should -BeExactly 'complete'
            $requests = if (Test-Path -LiteralPath $log) {
                @(Get-Content -LiteralPath $log)
            }
            else { @() }
            $requests | Should -HaveCount $ExpectedItems
            foreach ($request in $requests) {
                $request | Should -Match 'includeContent=true'
                $request | Should -Match 'includeContentMetadata=true'
            }
        }
        finally {
            Remove-Item Env:\ACTIVE_PR_INTAKE_EMPTY_CHANGE,
                Env:\ACTIVE_PR_INTAKE_EMPTY_LOG -ErrorAction SilentlyContinue
        }
    }
    It 'pins Azure CLI transport to GET, organization, project, repository and account' {
        $c = New-IntakeCase -Count 1
        $c.config.enabled = $false
        [void](Invoke-IntakeCase $c)
        New-Item -ItemType Directory -Path $c.root -Force | Out-Null
        $stub = Join-Path $c.root 'az-read-stub.ps1'
        $log = Join-Path $c.root 'az-requests.log'
        $credentialSnapshot = Set-IntakeCredentialSentinels
        $env:ACTIVE_PR_INTAKE_TEST_LOG = $log
        try {
            @'
$CliArguments = $args
[IO.File]::AppendAllText(
    $env:ACTIVE_PR_INTAKE_TEST_LOG,
    (ConvertTo-Json -InputObject ([string[]]$CliArguments) -Compress) + "`n")
$global:LASTEXITCODE = 0
if ($env:AZURE_DEVOPS_EXT_PAT -or $env:SYSTEM_ACCESSTOKEN) {
    exit 8
}
if ($CliArguments -contains 'account' -and $CliArguments -contains 'show') {
    '{"user":{"name":"service@example.invalid"}}'
} elseif ($CliArguments -contains '-c') {
    '{"authenticatedUser":{"id":"33333333-3333-3333-3333-333333333333","descriptor":"aad.synthetic-service-account"}}'
} elseif ($CliArguments -contains 'pullRequestIterations') {
    '{"value":[{"id":1,"sourceRefCommit":{"commitId":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"targetRefCommit":{"commitId":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}}]}'
} elseif ($CliArguments -contains 'pullRequestIterationChanges') {
    '{"changeEntries":[]}'
} elseif ($CliArguments -contains 'pullRequestThreads') {
    '{"value":[],"count":0}'
} elseif ($CliArguments -contains 'pullRequestId=1') {
    '{"pullRequestId":1,"status":"active","isDraft":false,"sourceRefName":"refs/heads/feature","targetRefName":"refs/heads/master","repository":{"id":"11111111-1111-1111-1111-111111111111","project":{"id":"22222222-2222-2222-2222-222222222222"}}}'
} elseif ($CliArguments -contains '$skip=1') {
    '{"value":[],"count":0}'
} else {
    '{"value":[{"pullRequestId":1,"status":"active","isDraft":false,"targetRefName":"refs/heads/master","repository":{"id":"11111111-1111-1111-1111-111111111111","project":{"id":"22222222-2222-2222-2222-222222222222"}}}],"count":1}'
}
'@ | Set-Content -LiteralPath $stub -Encoding utf8
            $transport = New-ActivePrAzureDevOpsProvider `
                -Config $c.config -AzureCliPath $stub `
                -ConnectionDataToolPath $stub
            $identity = & $transport 'Identity' @{}
            $identity.uniqueName | Should -Be 'service@example.invalid'
            $page = & $transport 'ListPage' @{ pass = 1; skip = 0; top = 3 }
            $page.items[0].pullRequestId | Should -Be 1
            $requests = @(Get-Content -LiteralPath $log | ForEach-Object {
                    , ($_ | ConvertFrom-Json)
                })
            $requests.Count | Should -Be 3
            ($requests[0] -join '|') | Should -Match '^account\|show\|'
            ($requests[0] -join '|') |
                Should -Not -Match 'devops\|invoke|--organization'
            ($requests[1] -join '|') |
                Should -Match '^-I\|-c\|'
            ($requests[1] -join '|') |
                Should -Match 'get_connection_data'
            ($requests[1] -join '|') | Should -Match `
                '\|https://dev.azure.com/example-org$'
            ($requests[1] -join '|') | Should -Not -Match `
                'POST|PATCH|PUT|DELETE|--in-file'
            ($requests[1] -join '|') | Should -Not -Match `
                'devops\|invoke|\|location\||\|connectionData\|'
            ($requests[2] -join '|') |
                Should -Match '\|--http-method\|GET\|'
            ($requests[2] -join '|') | Should -Match `
                '\|--organization\|https://dev.azure.com/example-org\|'
            ($requests[2] -join '|') |
                Should -Match 'project=ExampleProject'
            ($requests[2] -join '|') | Should -Match `
                'repositoryId=11111111-1111-1111-1111-111111111111'
            $c.config.enabled = $true
            $liveShape = Invoke-ActivePrIntake -Config $c.config -Provider $transport `
                -StateRoot $c.root -RepositoryRoot $repo -Run
            $liveShape.inventory.discovered | Should -Be 1
            $liveShape.heads[0].reasonCode | Should -Be 'rules-incomplete'
            $liveShape.heads[0].status | Should -Be 'pending'
            $liveShape.rules[0].evaluated | Should -Be 0
            $liveShape.rules[0].pending | Should -Be 1
            $liveShape.unmetCapabilities | Should -BeNullOrEmpty
            foreach ($request in @(Get-Content -LiteralPath $log |
                    ForEach-Object { , ($_ | ConvertFrom-Json) })) {
                $requestText = $request -join '|'
                if ($requestText -notmatch '^account\|show\|' -and
                    $requestText -notmatch '^-I\|-c\|') {
                    $requestText | Should -Match '\|--http-method\|GET\|'
                }
            }
            if ($IsWindows) {
                $cmdRoot = Join-Path $c.root 'command path with spaces'
                New-Item -ItemType Directory -Path $cmdRoot -Force |
                    Out-Null
                $cmd = Join-Path $cmdRoot 'az-read-stub.cmd'
                $cmdLog = Join-Path $cmdRoot 'arguments.log'
                $env:ACTIVE_PR_INTAKE_CMD_LOG = $cmdLog
                @'
@echo off
echo %*>>"%ACTIVE_PR_INTAKE_CMD_LOG%"
if "%~1"=="account" (
  echo {"user":{"name":"service@example.invalid"}}
) else (
  echo {"authenticatedUser":{"id":"33333333-3333-3333-3333-333333333333","descriptor":"aad.synthetic-service-account"}}
)
'@ | Set-Content -LiteralPath $cmd -Encoding ascii
                $cmdTransport = New-ActivePrAzureDevOpsProvider `
                    -Config $c.config -AzureCliPath $cmd `
                    -ConnectionDataToolPath $stub
                (& $cmdTransport 'Identity' @{ timeoutMilliseconds = 3000 }).id |
                    Should -Be '33333333-3333-3333-3333-333333333333'
                $cmdRequests = @(Get-Content -LiteralPath $cmdLog)
                $cmdRequests | Should -HaveCount 1
                $cmdRequests[0] | Should -Match '^"account" "show" '
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
        finally {
            Remove-Item Env:\ACTIVE_PR_INTAKE_TEST_LOG `
                -ErrorAction SilentlyContinue
            Remove-Item Env:\ACTIVE_PR_INTAKE_CMD_LOG `
                -ErrorAction SilentlyContinue
            Restore-IntakeCredentialEnvironment $credentialSnapshot
        }
    }
It 'uses the installed SDK connectionData seam with the same private context' `
    -Skip:(-not $IsWindows) -TestCases @(
        @{ Mode = 'valid'; Expected = 'valid' }
        @{ Mode = 'mismatch-id'; Expected = 'account-mismatch' }
        @{ Mode = 'mismatch-subject'; Expected = 'account-mismatch' }
        @{ Mode = 'missing-subject'
            Expected = 'identity-response-invalid' }
    ) {
    param($Mode, $Expected)
    $c = New-IntakeCase -Count 1
    New-Item -ItemType Directory -Path $c.root -Force | Out-Null
    $configRoot = Join-Path $c.root "azure-config-$Mode"
    $moduleRoot = Join-Path $configRoot (
        'cliextensions\azure-devops\azext_devops\dev\common')
    New-Item -ItemType Directory -Path $moduleRoot -Force | Out-Null
    foreach ($package in @(
            (Split-Path -Parent (Split-Path -Parent $moduleRoot)),
            (Split-Path -Parent $moduleRoot),
            $moduleRoot
        )) {
        '' | Set-Content -LiteralPath (
            Join-Path $package '__init__.py') -Encoding utf8
    }
    $sdkLog = Join-Path $c.root "sdk-$Mode.json"
    @'
import json
import os

class Identity:
    def __init__(self, identifier, descriptor, subject_descriptor):
        self.id = identifier
        self.descriptor = descriptor
        self.subject_descriptor = subject_descriptor

class ConnectionData:
    def __init__(self, identity):
        self.authenticated_user = identity

def get_connection_data(organization):
    with open(os.environ['ACTIVE_PR_INTAKE_SDK_LOG'], 'w',
              encoding='utf-8') as stream:
        json.dump({
            'organization': organization,
            'hasPat': 'AZURE_DEVOPS_EXT_PAT' in os.environ,
            'hasSystemToken': 'SYSTEM_ACCESSTOKEN' in os.environ
        }, stream)
    mode = os.environ['ACTIVE_PR_INTAKE_SDK_MODE']
    if mode == 'mismatch-id':
        return ConnectionData(Identity(
            '99999999-9999-9999-9999-999999999999',
            'legacy.synthetic-service-account',
            'aad.synthetic-service-account'))
    if mode == 'mismatch-subject':
        return ConnectionData(Identity(
            '33333333-3333-3333-3333-333333333333',
            'legacy.synthetic-service-account', 'aad.other'))
    if mode == 'missing-subject':
        return ConnectionData(Identity(
            '33333333-3333-3333-3333-333333333333',
            'aad.synthetic-service-account', None))
    return ConnectionData(Identity(
        '33333333-3333-3333-3333-333333333333',
        'legacy.synthetic-service-account',
        'aad.synthetic-service-account'))
'@ | Set-Content -LiteralPath (
        Join-Path $moduleRoot 'services.py') -Encoding utf8
    $accountStub = Join-Path $c.root 'az-account-metadata.ps1'
    @'
if ($env:AZURE_DEVOPS_EXT_PAT -or $env:SYSTEM_ACCESSTOKEN) {
    exit 8
}
'{"user":{"name":"local-profile@example.invalid"}}'
'@ | Set-Content -LiteralPath $accountStub -Encoding utf8
    $azureCliCommands = @(Get-Command az -CommandType Application `
            -ErrorAction Stop | Where-Object {
            [IO.Path]::GetExtension($_.Source) -ceq '.cmd'
        })
    $azureCliCommands | Should -HaveCount 1
    $python = Join-Path (
        Split-Path -Parent (
            Split-Path -Parent $azureCliCommands[0].Source)
    ) 'python.exe'
    Test-Path -LiteralPath $python -PathType Leaf | Should -BeTrue
    $outerConfig = $env:AZURE_CONFIG_DIR
    $credentialSnapshot = Set-IntakeCredentialSentinels
    try {
        $env:AZURE_CONFIG_DIR = $configRoot
        $env:ACTIVE_PR_INTAKE_SDK_LOG = $sdkLog
        $env:ACTIVE_PR_INTAKE_SDK_MODE = $Mode
        $transport = New-ActivePrAzureDevOpsProvider `
            -Config $c.config -AzureCliPath $accountStub `
            -ConnectionDataToolPath $python
        if ($Expected -ceq 'valid') {
            $identity = & $transport 'Identity' @{
                timeoutMilliseconds = 3000
            }
            $identity.id | Should -BeExactly $c.config.expectedAccount.id
            $identity.descriptor |
                Should -BeExactly $c.config.expectedAccount.descriptor
            $identity.uniqueName |
                Should -BeExactly $c.config.expectedAccount.uniqueName
        }
        else {
            { & $transport 'Identity' @{
                    timeoutMilliseconds = 3000
                } } | Should -Throw $Expected
        }
        $sdkInvocation = Get-Content -LiteralPath $sdkLog -Raw |
            ConvertFrom-Json -AsHashtable
        $sdkInvocation.organization |
            Should -BeExactly $c.config.organization
        $sdkInvocation.hasPat | Should -BeFalse
        $sdkInvocation.hasSystemToken | Should -BeFalse
    }
    finally {
        $env:AZURE_CONFIG_DIR = $outerConfig
        Remove-Item Env:\ACTIVE_PR_INTAKE_SDK_LOG,
            Env:\ACTIVE_PR_INTAKE_SDK_MODE -ErrorAction SilentlyContinue
        Restore-IntakeCredentialEnvironment $credentialSnapshot
    }
}
It 'retains command resolution validation and empty response stages' `
    -Skip:(-not $IsWindows) -TestCases @(
        @{ Name = 'missing'; ExpectedStage = 'command-resolution'
            ExpectedType = 'CommandNotFoundException' }
        @{ Name = 'metachar'; ExpectedStage = 'command-validation'
            ExpectedType = 'RuntimeException' }
        @{ Name = 'empty'; ExpectedStage = 'response-empty'
            ExpectedType = $null }
    ) {
    param($Name, $ExpectedStage, $ExpectedType)
    $c = New-IntakeCase -Count 1
    New-Item -ItemType Directory -Path $c.root -Force | Out-Null
    $stateRoot = Join-Path $c.root "state-$Name"
    $stub = switch ($Name) {
        missing {
            Join-Path $c.root 'missing command path\az-missing.cmd'
        }
        metachar {
            $unsafeRoot = Join-Path $c.root 'unsafe&command'
            New-Item -ItemType Directory -Path $unsafeRoot -Force |
                Out-Null
            $path = Join-Path $unsafeRoot 'az-refused.cmd'
            '@echo off' | Set-Content -LiteralPath $path -Encoding ascii
            $path
        }
        empty {
            $emptyRoot = Join-Path $c.root 'empty command path'
            New-Item -ItemType Directory -Path $emptyRoot -Force |
                Out-Null
            $path = Join-Path $emptyRoot 'az-empty.cmd'
            "@echo off`r`nexit /b 0" |
                Set-Content -LiteralPath $path -Encoding ascii
            $path
        }
    }
    $transport = New-ActivePrAzureDevOpsProvider `
        -Config $c.config -AzureCliPath $stub
    $result = Invoke-ActivePrIntake `
        -Config $c.config -Provider $transport `
        -StateRoot $stateRoot -RepositoryRoot $repo -Run

    $result.state | Should -BeExactly 'unknown'
    $result.reasonCodes | Should -Be @('identity-read-inaccessible')
    $diagnostic = Get-ChildItem -LiteralPath (
        Join-Path $stateRoot 'active-pr-intake-v1\diagnostics') `
        -File -Filter '*.json' |
        Select-Object -First 1 |
        ForEach-Object {
            Get-Content -LiteralPath $_.FullName -Raw |
                ConvertFrom-Json -AsHashtable -Depth 8
        }
    $diagnostic.identityStage | Should -BeExactly 'account'
    $diagnostic.transportStage | Should -BeExactly $ExpectedStage
    $diagnostic.underlyingExceptionType | Should -BeExactly $ExpectedType
    if ($Name -ceq 'empty') {
        $diagnostic.nativeExitCode | Should -Be 0
        $diagnostic.stderrCategory | Should -BeExactly 'none'
        $diagnostic.stderrByteCount | Should -Be 0
        $diagnostic.stderrSha256 | Should -BeNullOrEmpty
    }
    ($diagnostic | ConvertTo-Json -Depth 8) |
        Should -Not -Match 'missing command path|unsafe&command|empty command path'
}
It 'preserves identity read and response failures as explicit predicates' `
    -TestCases @(
        @{ Name = 'read'; ExitCode = 7; Body = '' }
        @{ Name = 'malformed'; ExitCode = 0; Body = '{not-json' }
        @{ Name = 'shape'; ExitCode = 0
            Body = '{"authenticatedUser":{}}' }
        @{ Name = 'account'; ExitCode = 0
            Body = '{"authenticatedUser":{"id":"99999999-9999-9999-9999-999999999999","descriptor":"aad.other","uniqueName":"other@example.invalid"}}' }
    ) {
    param($Name, $ExitCode, $Body)
    $c = New-IntakeCase -Count 1
    New-Item -ItemType Directory -Path $c.root -Force | Out-Null
    $stub = Join-Path $c.root "az-identity-$Name.ps1"
    @"
if (`$args -contains 'account' -and `$args -contains 'show') {
    if ('$Name' -eq 'read') { exit $ExitCode }
    '{"user":{"name":"service@example.invalid"}}'
    exit 0
}
if (`$args -notcontains '-c') { exit 9 }
'$Body'
"@ | Set-Content -LiteralPath $stub -Encoding utf8
    $transport = New-ActivePrAzureDevOpsProvider `
        -Config $c.config -AzureCliPath $stub `
        -ConnectionDataToolPath $stub
    $expected = switch ($Name) {
        read { 'identity-read-inaccessible' }
        malformed { 'identity-response-invalid' }
        shape { 'identity-response-invalid' }
        account { 'account-mismatch' }
    }
    { & $transport 'Identity' @{ timeoutMilliseconds = 3000 } } |
        Should -Throw $expected
}
It 'retains bounded private native identity failure metadata only' {
    $c = New-IntakeCase -Count 1
    New-Item -ItemType Directory -Path $c.root -Force | Out-Null
    $stub = Join-Path $c.root 'az-private-identity-failure.ps1'
    @'
[Console]::Error.Write('HTTP 403 forbidden AADSTS50076 private sentinel')
exit 7
'@ | Set-Content -LiteralPath $stub -Encoding utf8
    $transport = New-ActivePrAzureDevOpsProvider `
        -Config $c.config -AzureCliPath $stub
    $result = Invoke-ActivePrIntake `
        -Config $c.config -Provider $transport `
        -StateRoot $c.root -RepositoryRoot $repo -Run

    $result.state | Should -BeExactly 'unknown'
    $result.reasonCodes | Should -Be @('identity-read-inaccessible')
    ($result | ConvertTo-Json -Depth 32) |
        Should -Not -Match 'private sentinel|403|forbidden'
    $diagnostic = Get-ChildItem -LiteralPath (
        Join-Path $c.root 'active-pr-intake-v1\diagnostics') `
        -File -Filter '*.json' |
        Select-Object -First 1 |
        ForEach-Object {
            Get-Content -LiteralPath $_.FullName -Raw |
                ConvertFrom-Json -AsHashtable -Depth 8
        }
    $diagnostic.kind |
        Should -BeExactly 'active-pr-intake-private-failure'
    $diagnostic.predicate | Should -BeExactly 'identity-read-inaccessible'
    $diagnostic.identityStage | Should -BeExactly 'account'
    $diagnostic.transportStage | Should -BeExactly 'process-exit'
    $diagnostic.nativeExitCode | Should -Be 7
    $diagnostic.httpStatus | Should -Be 403
    $diagnostic.stderrCategory | Should -BeExactly 'authorization'
    $diagnostic.externalErrorCode | Should -BeExactly 'AADSTS50076'
    $diagnostic.stderrSha256 | Should -Match '^[0-9a-f]{64}$'
    $diagnostic.stderrByteCount | Should -BeGreaterThan 0
    (Get-Item -LiteralPath (
            Get-ChildItem -LiteralPath (
                Join-Path $c.root 'active-pr-intake-v1\diagnostics') `
                -File -Filter '*.json' |
                Select-Object -First 1
        ).FullName).Length | Should -BeLessOrEqual 4096
    ((Get-Item -LiteralPath (
        Get-ChildItem -LiteralPath (
            Join-Path $c.root 'active-pr-intake-v1\diagnostics') `
            -File -Filter '*.json' |
            Select-Object -First 1
        ).FullName).Attributes -band
        [IO.FileAttributes]::ReparsePoint) | Should -Be 0
    ($diagnostic | ConvertTo-Json -Depth 8) |
        Should -Not -Match 'private sentinel|forbidden'
}
It 'bounds captured AADSTS codes to ten digits' {
    $valid = & (Get-Module DevPilot.ActivePrIntake) {
        New-IntakeTransportFailure `
            -Message read-inaccessible -NativeExitCode 1 `
            -StderrBytes ([Text.Encoding]::UTF8.GetBytes(
                'AADSTS1234567890'))
    }
    $valid.Data['externalErrorCode'] |
        Should -BeExactly 'AADSTS1234567890'
    $tooLong = & (Get-Module DevPilot.ActivePrIntake) {
        New-IntakeTransportFailure `
            -Message read-inaccessible -NativeExitCode 1 `
            -StderrBytes ([Text.Encoding]::UTF8.GetBytes(
                'AADSTS12345678901'))
    }
    $tooLong.Data.Contains('externalErrorCode') | Should -BeFalse
}
It 'unwraps method invocation exceptions for native diagnostics' {
    $native = [ComponentModel.Win32Exception]::new(2)
    $wrapped = [Management.Automation.MethodInvocationException]::new(
        'wrapped', $native)
    $failure = & (Get-Module DevPilot.ActivePrIntake) {
        param($Source)
        New-IntakeTransportFailure `
            -Message read-inaccessible `
            -TransportStage process-start `
            -SourceException $Source
    } $wrapped
    $failure.Data['underlyingExceptionType'] |
        Should -BeExactly 'Win32Exception'
    $failure.Data['nativeErrorCode'] | Should -Be 2
    $failure.Data['hResult'] | Should -Be $native.HResult
}
It 'does not let a private diagnostic write failure mask identity refusal' {
    $c = New-IntakeCase -Count 1
    $privateRoot = Join-Path $c.root 'active-pr-intake-v1'
    New-Item -ItemType Directory -Path $privateRoot -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $privateRoot 'diagnostics') `
        -Value 'blocks diagnostic directory' -Encoding utf8
    $stub = Join-Path $c.root 'az-private-diagnostic-block.ps1'
    @'
[Console]::Error.Write('HTTP 401 authentication failed')
exit 9
'@ | Set-Content -LiteralPath $stub -Encoding utf8
    $transport = New-ActivePrAzureDevOpsProvider `
        -Config $c.config -AzureCliPath $stub
    $originalError = [Console]::Error
    $capturedError = [IO.StringWriter]::new()
    try {
        [Console]::SetError($capturedError)
        $result = Invoke-ActivePrIntake `
            -Config $c.config -Provider $transport `
            -StateRoot $c.root -RepositoryRoot $repo -Run

        $result.state | Should -BeExactly 'unknown'
        $result.reasonCodes | Should -Be @('identity-read-inaccessible')
        $result.readCount | Should -Be 1
        Test-Path -LiteralPath (
            Join-Path $privateRoot 'diagnostics') -PathType Leaf |
            Should -BeTrue
    }
    finally {
        [Console]::SetError($originalError)
        $capturedText = $capturedError.ToString()
        $capturedError.Dispose()
    }
    $capturedText.Trim() |
        Should -BeExactly 'private-diagnostic-capture-failed'
    $capturedText | Should -Not -Match `
        'HTTP|authentication failed|diagnostics|intake-pester'
}
It 'treats local account UPN as metadata, not ADO identity authority' {
    $c = New-IntakeCase -Count 1
    New-Item -ItemType Directory -Path $c.root -Force | Out-Null
    $stub = Join-Path $c.root 'az-upn-metadata.ps1'
    @'
if ($args -contains 'account' -and $args -contains 'show') {
    '{"user":{"name":"different-local-profile@example.invalid"}}'
}
elseif ($args -contains '-c') {
    '{"authenticatedUser":{"id":"33333333-3333-3333-3333-333333333333","descriptor":"aad.synthetic-service-account"}}'
}
else {
    exit 9
}
'@ | Set-Content -LiteralPath $stub -Encoding utf8
    $transport = New-ActivePrAzureDevOpsProvider `
        -Config $c.config -AzureCliPath $stub `
        -ConnectionDataToolPath $stub
    $identity = & $transport 'Identity' @{
        timeoutMilliseconds = 3000
    }
    $identity.id | Should -BeExactly $c.config.expectedAccount.id
    $identity.descriptor |
        Should -BeExactly $c.config.expectedAccount.descriptor
    $identity.uniqueName | Should -BeExactly `
        $c.config.expectedAccount.uniqueName
}
It 'restores caller credential environment when originally <State>' `
    -TestCases @(
        @{ State = 'absent' }
        @{ State = 'present' }
    ) {
    param($State)
    $outer = Save-IntakeCredentialEnvironment
    try {
        if ($State -ceq 'present') {
            [Environment]::SetEnvironmentVariable(
                'AZURE_DEVOPS_EXT_PAT',
                'original-pat-value',
                [EnvironmentVariableTarget]::Process)
            [Environment]::SetEnvironmentVariable(
                'SYSTEM_ACCESSTOKEN',
                'original-system-value',
                [EnvironmentVariableTarget]::Process)
        }
        else {
            [Environment]::SetEnvironmentVariable(
                'AZURE_DEVOPS_EXT_PAT', $null,
                [EnvironmentVariableTarget]::Process)
            [Environment]::SetEnvironmentVariable(
                'SYSTEM_ACCESSTOKEN', $null,
                [EnvironmentVariableTarget]::Process)
        }
        $expected = Save-IntakeCredentialEnvironment
        $snapshot = Set-IntakeCredentialSentinels
        try {
            throw 'simulated assertion failure'
        }
        catch {
            [string]$_.Exception.Message |
                Should -BeExactly 'simulated assertion failure'
        }
        finally {
            Restore-IntakeCredentialEnvironment $snapshot
        }
        $actual = Save-IntakeCredentialEnvironment
        $actual.patPresent | Should -Be $expected.patPresent
        $actual.systemPresent | Should -Be $expected.systemPresent
        if ($State -ceq 'present') {
            $actual.patValue | Should -BeExactly 'original-pat-value'
            $actual.systemValue |
                Should -BeExactly 'original-system-value'
        }
    }
    finally {
        Restore-IntakeCredentialEnvironment $outer
    }
}
}
