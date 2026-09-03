#!/usr/bin/env pwsh
[CmdletBinding()]
param([string]$RepoRoot = (Split-Path -Parent $PSScriptRoot))

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Import-Module (Join-Path $RepoRoot 'src/DevPilot.AgentHarness/DevPilot.AgentHarness.psd1') -Force
. (Join-Path $RepoRoot 'src/Agents/reviewer/CorpusSeal.ps1')
. (Join-Path $RepoRoot 'src/Agents/reviewer/ConventionSpecialist.ps1')
. (Join-Path $RepoRoot 'src/Agents/reviewer/AcquisitionPackage.ps1')
. (Join-Path $RepoRoot 'src/Agents/reviewer/OwnerPreviewSubject.ps1')
. (Join-Path $RepoRoot 'src/Agents/reviewer/OwnerPreviewReport.ps1')
. (Join-Path $RepoRoot 'src/Agents/reviewer/OwnerPreviewQueue.ps1')

$script:Checks = 0
$script:Failures = [Collections.Generic.List[string]]::new()

function Assert-QueueTest {
    param([bool]$Condition, [string]$Message)
    $script:Checks++
    if (-not $Condition) { [void]$script:Failures.Add($Message) }
}

function Test-QueueRefusal {
    param([scriptblock]$Action, [string]$Pattern, [string]$Message)
    $refused = $false
    try { & $Action }
    catch { $refused = [string]$_.Exception.Message -match $Pattern }
    Assert-QueueTest $refused $Message
}

function New-QueueTestRoot {
    $path = Join-Path ([IO.Path]::GetTempPath()) ('owner-queue-test-' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $path)
    return $path
}

$testRoot = New-QueueTestRoot
try {
    $agency = Join-Path $testRoot 'agency.exe'
    [IO.File]::WriteAllBytes($agency, [byte[]](1))
    $reviewerConfig = (Resolve-Path (Join-Path $RepoRoot 'samples/azureux-bpm-convention-packs.preview.json')).Path
    $toolkit = (Resolve-Path $RepoRoot).Path
    $toolkitHead = ([string](& git -C $toolkit rev-parse HEAD)).Trim()
    $toolkitRef = ([string](& git -C $toolkit symbolic-ref -q HEAD)).Trim()

    function New-TestEntry {
        param([int]$PullRequestId, [string]$Head = ('a' * 40), [string]$Mode = 'fixed')
        $entry = [ordered]@{
            capability = 'bpm-test-ownership@1'
            organization = 'contoso'
            project = 'Widgets'
            repositoryId = '11111111-2222-3333-4444-555555555555'
            repositoryName = 'Widgets'
            pullRequestId = $PullRequestId
            targetRefName = 'refs/heads/main'
            sourceHeadMode = $Mode
            configPath = $reviewerConfig
            authoritativeRuleCommit = ('b' * 40)
            model = 'claude-sonnet-5'
            expectedReviewerBaseCommit = ('c' * 40)
            agencyPath = $agency
        }
        if ($Mode -ceq 'fixed') { $entry.expectedSourceHead = $Head }
        return $entry
    }

    function Write-TestQueue {
        param([string]$Path, [object[]]$Entries, [string]$Instance = 'test')
        $value = [ordered]@{
            schemaVersion = 1
            kind = 'reviewer-owner-preview-queue'
            instanceName = $Instance
            toolkitRoot = $toolkit
            expectedToolkitHead = $toolkitHead
            expectedToolkitRef = $toolkitRef
            entries = $Entries
        }
        [void](Write-OwnerPreviewJsonFile -Path $Path -Value $value)
        return $value
    }

    $queuePath = Join-Path $testRoot 'queue.json'
    [void](Write-TestQueue -Path $queuePath -Entries @((New-TestEntry 101)))
    $config = Read-OwnerPreviewQueueConfig -Path $queuePath -RepoRoot $RepoRoot
    Assert-QueueTest (@($config.entries).Count -eq 1) 'A valid one-entry queue did not load.'
    Assert-QueueTest ([string]$config.entries[0].capability -ceq 'bpm-test-ownership@1') 'Capability identity drifted while loading.'

    $tooManyPath = Join-Path $testRoot 'too-many.json'
    [void](Write-TestQueue -Path $tooManyPath -Entries @(1..11 | ForEach-Object { New-TestEntry (200 + $_) }))
    Test-QueueRefusal { Read-OwnerPreviewQueueConfig -Path $tooManyPath -RepoRoot $RepoRoot } 'does not satisfy' `
        'A queue with more than ten entries was accepted.'

    $badRefPath = Join-Path $testRoot 'bad-ref.json'
    $badRef = New-TestEntry 102
    $badRef.targetRefName = 'main; whoami'
    [void](Write-TestQueue -Path $badRefPath -Entries @($badRef))
    Test-QueueRefusal { Read-OwnerPreviewQueueConfig -Path $badRefPath -RepoRoot $RepoRoot } 'does not satisfy' `
        'An unsafe/non-full ref was accepted.'

    $refreshPath = Join-Path $testRoot 'refresh.json'
    [void](Write-TestQueue -Path $refreshPath -Entries @((New-TestEntry 103 -Mode 'refresh-before-first-run')))
    $refresh = Read-OwnerPreviewQueueConfig -Path $refreshPath -RepoRoot $RepoRoot
    Assert-QueueTest (-not $refresh.entries[0].Contains('expectedSourceHead')) 'Refresh mode unexpectedly acquired a pre-sealed head.'

    $fixedMissingPath = Join-Path $testRoot 'fixed-missing.json'
    $fixedMissing = New-TestEntry 104
    [void]$fixedMissing.Remove('expectedSourceHead')
    [void](Write-TestQueue -Path $fixedMissingPath -Entries @($fixedMissing))
    Test-QueueRefusal { Read-OwnerPreviewQueueConfig -Path $fixedMissingPath -RepoRoot $RepoRoot } 'does not satisfy' `
        'Fixed mode without an expected source head was accepted.'

    $duplicatePath = Join-Path $testRoot 'duplicate.json'
    [void](Write-TestQueue -Path $duplicatePath -Entries @((New-TestEntry 105), (New-TestEntry 105)))
    Test-QueueRefusal { Read-OwnerPreviewQueueConfig -Path $duplicatePath -RepoRoot $RepoRoot } 'declared more than once' `
        'A duplicate pull request identity was accepted.'

    $script:FakeMode = 'completed'
    $script:FakeProcessed = [Collections.Generic.List[int]]::new()
    $script:OwnerPreviewQueueTestDriver = {
        param($entry, $cfg, $intent, $cycleRoot, $beforeLaunch)
        [void]$script:FakeProcessed.Add([int]$entry.pullRequestId)
        if ($script:FakeMode -ceq 'prelaunch-block') { throw 'authentication/source/rule/head mismatch' }
        $source = if ($entry.Contains('expectedSourceHead')) { [string]$entry.expectedSourceHead } else { 'd' * 40 }
        $layerHead = Get-OwnerPreviewCanonicalSha256 -Value ([ordered]@{ pr = [int]$entry.pullRequestId; source = $source })
        $subject = [ordered]@{
            headKey = $layerHead
            subject = [ordered]@{
                organization = [string]$entry.organization
                project = [string]$entry.project
                repositoryId = [string]$entry.repositoryId
                repositoryName = [string]$entry.repositoryName
                pullRequestId = [int]$entry.pullRequestId
                sourceCommit = $source
                targetCommit = ('e' * 40)
                targetRefName = [string]$entry.targetRefName
            }
            snapshot = [ordered]@{ manifestDigest = Get-OwnerPreviewCanonicalSha256 -Value ([ordered]@{ source = $source }) }
        }
        $ready = [pscustomobject]@{ headKey = $layerHead }
        & $beforeLaunch $ready $subject
        if ($script:FakeMode -ceq 'crash') { throw 'synthetic process crash' }
        $writes = if ($script:FakeMode -ceq 'write') { 1 } else { 0 }
        $starts = if ($script:FakeMode -ceq 'over-budget') { 4 } else { 1 }
        $generalists = if ($script:FakeMode -ceq 'generalist') { 1 } else { 0 }
        $terminal = if ($script:FakeMode -ceq 'blocked') { 'blocked' } else { 'completed' }
        $ruleSource = @($intent.Material.rules)[0]
        $status = @{
            schemaVersion = 1
            kind = 'reviewer-owner-preview-status'
            capability = 'bpm-test-ownership@1'
            subject = $subject.subject
            rule = @{
                path = [string]$ruleSource.path
                commit = [string]$ruleSource.commit
                sha256 = [string]$ruleSource.sha256
                byteLength = [int]$ruleSource.byteLength
                section = [string]$ruleSource.section
            }
            snapshot = @{
                snapshotId = "pr$($entry.pullRequestId)-synthetic"
                manifestDigest = [string]$subject.snapshot.manifestDigest
                sealKind = 'offlineCorpusSeal'
                nonPromotable = $true
            }
            terminal = @{
                status = $terminal
                markerStatus = $(if ($terminal -ceq 'completed') { 'success' } else { 'wrongBinding' })
                contractVersion = 4
            }
            counts = @{ checked = 1; violations = 1; compliant = 0; unknown = 0; notInReach = 2; notRouted = 3 }
            spend = @{
                attempts = [Math]::Min($starts, 3)
                modelStarts = $starts
                providerWriteCount = $writes
                writeToolInvocations = $writes
                generalistModelStarts = $generalists
                specialistModel = [string]$entry.model
            }
            createdUtc = '2026-09-03T00:00:00Z'
        }
        $subjectRoot = Join-Path $cycleRoot 'evidence'
        $runRoot = Join-Path (Join-Path $subjectRoot 'runs') $layerHead
        [void](New-Item -ItemType Directory -Force -Path $runRoot)
        [void](Write-OwnerPreviewJsonFile -Path (Join-Path $runRoot 'owner-preview-status.json') -Value $status)
        return [pscustomobject]@{
            Ready = $ready
            Subject = $subject
            Status = $status
            ExitCode = 0
            DurationMs = 17
            SubjectRoot = $subjectRoot
        }
    }

    $orderPath = Join-Path $testRoot 'order.json'
    [void](Write-TestQueue -Path $orderPath -Entries @((New-TestEntry 201), (New-TestEntry 202)))
    $orderConfig = Read-OwnerPreviewQueueConfig -Path $orderPath -RepoRoot $RepoRoot
    $orderState = Join-Path $testRoot 'order-state'
    [void](New-Item -ItemType Directory -Path $orderState)
    $first = Invoke-OwnerPreviewQueueTick -Config $orderConfig -StateRoot $orderState
    Assert-QueueTest ([int]$first.processed -eq 1 -and $script:FakeProcessed[0] -eq 201) `
        'The first tick did not process exactly the first declared entry.'
    $second = Invoke-OwnerPreviewQueueTick -Config $orderConfig -StateRoot $orderState
    Assert-QueueTest ($script:FakeProcessed[1] -eq 202) 'The second tick did not preserve declared order.'
    $third = Invoke-OwnerPreviewQueueTick -Config $orderConfig -StateRoot $orderState
    Assert-QueueTest ([string]$third.outcome -ceq 'noEligibleEntry') 'A fully processed queue did not report no eligible entry.'
    Assert-QueueTest ([int]$first.index.records[0].counts.notInReach -eq 2 -and
        [int]$first.index.records[0].counts.notRouted -eq 3) 'Reach and routing omissions were not reported separately.'
    Assert-QueueTest ([int]$first.index.records[0].counts.violations -eq 1) 'The synthetic Owner finding was not indexed.'
    Assert-QueueTest ([int]$first.index.records[0].providerWriteCount -eq 0 -and
        [int]$first.index.records[0].generalistModelStarts -eq 0) 'The successful offline run did not prove zero writes/generalists.'

    $dedupeState = Join-Path $testRoot 'dedupe-state'
    [void](New-Item -ItemType Directory -Path $dedupeState)
    $single = Read-OwnerPreviewQueueConfig -Path $queuePath -RepoRoot $RepoRoot
    $beforeCount = $script:FakeProcessed.Count
    $one = Invoke-OwnerPreviewQueueTick -Config $single -StateRoot $dedupeState
    $two = Invoke-OwnerPreviewQueueTick -Config $single -StateRoot $dedupeState
    Assert-QueueTest ([string]$two.outcome -ceq 'noEligibleEntry' -and
        $script:FakeProcessed.Count -eq $beforeCount + 1) 'A repeat tick charged the same head/config twice.'

    $dedupeKey = Get-OwnerPreviewQueueKey -StateRoot $dedupeState
    Remove-Item -LiteralPath (Join-Path $dedupeState 'ledger.json') -Force
    Test-QueueRefusal { Read-OwnerPreviewQueueLedger -StateRoot $dedupeState -Key $dedupeKey } `
        'absent while queue evidence exists' 'Deleting the ledger reset completed-head dedupe state.'

    $changed = New-TestEntry 101 -Head ('f' * 40)
    $changedPath = Join-Path $testRoot 'changed.json'
    [void](Write-TestQueue -Path $changedPath -Entries @($changed))
    $changedConfig = Read-OwnerPreviewQueueConfig -Path $changedPath -RepoRoot $RepoRoot
    $changedState = Join-Path $testRoot 'changed-state'
    [void](New-Item -ItemType Directory -Path $changedState)
    $changedResult = Invoke-OwnerPreviewQueueTick -Config $changedConfig -StateRoot $changedState
    Assert-QueueTest ([string]$changedResult.headKey -cne [string]$one.headKey) 'A changed source head did not produce a new charge key.'

    $crashState = Join-Path $testRoot 'crash-state'
    [void](New-Item -ItemType Directory -Path $crashState)
    $script:FakeMode = 'crash'
    $crash = Invoke-OwnerPreviewQueueTick -Config $single -StateRoot $crashState
    Assert-QueueTest ([string]$crash.outcome -ceq 'incomplete') 'A post-running crash was not incomplete.'
    $script:FakeMode = 'completed'
    $crashAgain = Invoke-OwnerPreviewQueueTick -Config $single -StateRoot $crashState
    Assert-QueueTest ([string]$crashAgain.outcome -ceq 'noEligibleEntry') 'An incomplete crash retried automatically.'

    $key = Get-OwnerPreviewQueueKey -StateRoot $crashState
    $ledger = Read-OwnerPreviewQueueLedger -StateRoot $crashState -Key $key
    $crashHead = [string]@($ledger.records.Keys)[0]
    $audit = Invoke-OwnerPreviewQueueRequeue -StateRoot $crashState -HeadKey $crashHead -Reason 'operator inspected crash'
    Assert-QueueTest ([string]$audit.reason -ceq 'operator inspected crash') 'Requeue did not retain its audit reason.'
    $retried = Invoke-OwnerPreviewQueueTick -Config $single -StateRoot $crashState
    Assert-QueueTest ([string]$retried.outcome -ceq 'completed') 'An audited requeue did not become eligible.'

    foreach ($mode in @('write', 'generalist', 'over-budget')) {
        $budgetState = Join-Path $testRoot "budget-$mode"
        [void](New-Item -ItemType Directory -Path $budgetState)
        $script:FakeMode = $mode
        $budget = Invoke-OwnerPreviewQueueTick -Config $single -StateRoot $budgetState
        Assert-QueueTest ([string]$budget.outcome -ceq 'blocked') "Budget mode '$mode' did not block."
    }

    $blockedState = Join-Path $testRoot 'blocked-state'
    [void](New-Item -ItemType Directory -Path $blockedState)
    $script:FakeMode = 'prelaunch-block'
    $blocked = Invoke-OwnerPreviewQueueTick -Config $single -StateRoot $blockedState
    Assert-QueueTest ([string]$blocked.outcome -ceq 'blocked') 'A prelaunch auth/source/rule/head refusal was not blocked.'
    $blockedAgain = Invoke-OwnerPreviewQueueTick -Config $single -StateRoot $blockedState
    Assert-QueueTest ([string]$blockedAgain.outcome -ceq 'noEligibleEntry') 'A blocked entry retried automatically.'
    $script:FakeMode = 'completed'

    $runningState = Join-Path $testRoot 'running-state'
    [void](New-Item -ItemType Directory -Path $runningState)
    $runningKey = Get-OwnerPreviewQueueKey -StateRoot $runningState
    $runningLedger = New-OwnerPreviewQueueLedger
    $runningIntent = Get-OwnerPreviewQueueIntent -Entry $single.entries[0] -Config $single
    $runningHead = '9' * 64
    $runningLedger.intents[$runningIntent.Key] = [ordered]@{ headKey = $runningHead; state = 'running'; attempts = 1 }
    $runningLedger.records[$runningHead] = [ordered]@{
        state = 'running'; intentKey = $runningIntent.Key; subject = @{}; rule = @{}
        terminal = @{ status = 'running'; markerStatus = 'modelStartReserved' }
        counts = @{ checked = 0; violations = 0; unknown = 0; notInReach = 0; notRouted = 0 }
        attempts = 1; startCount = 3; latencyMs = 0
        modelAttempts = 3
        providerWriteCount = 0; writeToolInvocations = 0; generalistModelStarts = 0
    }
    Save-OwnerPreviewQueueLedger -StateRoot $runningState -Ledger $runningLedger -Key $runningKey
    $recovered = Invoke-OwnerPreviewQueueTick -Config $single -StateRoot $runningState
    $runningLedger = Read-OwnerPreviewQueueLedger -StateRoot $runningState -Key $runningKey
    Assert-QueueTest ([string]$runningLedger.records[$runningHead].terminal.markerStatus -ceq 'interruptedUnknown') `
        'A dead running record was not recovered as interruptedUnknown.'
    Assert-QueueTest ([string]$recovered.outcome -ceq 'noEligibleEntry') 'Dead running recovery retried automatically.'

    $tamperPath = Join-Path $crashState 'ledger.json'
    $tampered = Get-Content -LiteralPath $tamperPath -Raw | ConvertFrom-Json -Depth 64
    $tampered.payload.sequence = 999
    $tampered | ConvertTo-Json -Depth 64 -Compress | Set-Content -LiteralPath $tamperPath -Encoding UTF8
    Test-QueueRefusal { Read-OwnerPreviewQueueLedger -StateRoot $crashState -Key $key } 'HMAC verification' `
        'A tampered ledger was accepted.'

    $missingKeyState = Join-Path $testRoot 'missing-key'
    [void](New-Item -ItemType Directory -Path $missingKeyState)
    [IO.File]::WriteAllText((Join-Path $missingKeyState 'ledger.json'), '{}')
    Test-QueueRefusal { Get-OwnerPreviewQueueKey -StateRoot $missingKeyState } 'key is missing' `
        'Records without a pre-existing key were silently re-keyed.'

    $lockPath = Join-Path $testRoot 'queue.lock'
    $lock = Enter-AgentLock -Path $lockPath -AgentName 'test'
    try {
        Test-QueueRefusal { Enter-AgentLock -Path $lockPath -AgentName 'second' } 'already holds the lock' `
            'Two queue instances acquired the same lock.'
    }
    finally { Exit-AgentLock -Stream $lock }

    $layerKeyRoot = Initialize-OwnerPreviewQueueLayerKeys -StateRoot (Join-Path $testRoot 'layer-keys')
    $entryKey = (Get-Content -LiteralPath (Join-Path $layerKeyRoot 'owner-preview-entry.key') -Raw).Trim()
    $runSetKey = (Get-Content -LiteralPath (Join-Path $layerKeyRoot 'owner-preview-run-set.key') -Raw).Trim()
    Assert-QueueTest ($entryKey -match '^raw:[A-Za-z0-9+/]{43}=$' -and
        $runSetKey -match '^[A-Za-z0-9+/]{43}=$') 'Layer 1 keys were not created in their required formats.'

    Test-QueueRefusal { Resolve-OwnerPreviewQueueStateRoot -StateRoot $RepoRoot -InstanceName 'test' } 'inside git' `
        'A repository state root was accepted.'
    Test-QueueRefusal { Assert-OwnerPreviewQueueStableToolkit -Config $config } 'worktree|ordinary checkout' `
        'The linked Copilot worktree was accepted as a scheduler toolkit.'
    Test-QueueRefusal { Assert-OwnerPreviewQueueSafePath -Path 'C:\bad"path' -Where 'test' } 'control character or quote' `
        'A quoted task path was accepted.'

    $plan = Get-OwnerPreviewQueueTaskPlan -Config $config -ConfigFile $queuePath -StateRoot (Join-Path $testRoot 'task-state')
    Assert-QueueTest ([string]$plan.taskName -ceq 'DevPilotOwnerPreview-test') 'Task name is not instance-bound.'
    Assert-QueueTest ([string]$plan.principal.logonType -ceq 'Interactive' -and
        [string]$plan.principal.runLevel -ceq 'Limited') 'Task principal is not interactive/limited.'
    Assert-QueueTest ([int]$plan.trigger.intervalMinutes -eq 60 -and
        [int]$plan.settings.executionTimeLimitMinutes -eq 55 -and
        [string]$plan.settings.multipleInstances -ceq 'IgnoreNew') 'Task trigger/settings drifted.'
    Assert-QueueTest ([string]$plan.arguments -match '-Action run' -and
        [string]$plan.arguments -notmatch 'copilot-worktrees.*-File') 'Task action is not the direct queue runner.'

    $toolText = Get-Content -LiteralPath (Join-Path $RepoRoot 'tools/Invoke-OwnerPreviewQueue.ps1') -Raw
    Assert-QueueTest ($toolText -notmatch 'Remove-Item.+StateRoot|Remove-Item.+ledger' -and
        $toolText -match 'Unregister-ScheduledTask') 'Disable/uninstall can remove ledger evidence.'
    Assert-QueueTest ($toolText -notmatch 'create_session|create_worktree|save_workflow|App Automation') `
        'The shipped scheduler contains an app session/worktree/workflow path.'
}
finally {
    $script:OwnerPreviewQueueTestDriver = $null
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}

if ($script:Failures.Count -gt 0) {
    $script:Failures | ForEach-Object { Write-Error $_ }
    throw "Owner preview queue: $($script:Failures.Count) of $($script:Checks) checks failed."
}
Write-Host "Owner preview queue: $($script:Checks) checks passed."
