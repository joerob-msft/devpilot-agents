BeforeAll {
    Import-Module "$PSScriptRoot\..\src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1" -Force
    $script:repoRoot = (Resolve-Path "$PSScriptRoot\..").Path
    $script:identity = [ordered]@{
        schemaVersion = 1
        provider = 'AzureDevOps'
        repositoryId = '11111111-2222-3333-4444-555555555555'
        organization = 'contoso'
        project = 'widgets'
        repositoryName = 'service'
        slug = 'contoso/widgets/service'
        key = 'v1:azuredevops:11111111-2222-3333-4444-555555555555'
        verifiedAtUtc = [DateTime]::UtcNow.ToString('o')
        verified = $true
        dispatchEligible = $true
    }
}

Describe 'trusted durable and lease roots' {
    BeforeEach {
        $script:suiteRoot = Join-Path $TestDrive ([Guid]::NewGuid().ToString('N'))
        $script:durableRoot = Join-Path $suiteRoot 'durable'
        $script:leaseRoot = Join-Path $suiteRoot 'leases'
        New-Item -ItemType Directory -Path $suiteRoot | Out-Null
        if (-not $IsWindows) {
            [IO.File]::SetUnixFileMode($suiteRoot,
                [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite -bor [IO.UnixFileMode]::UserExecute)
        }
        $script:durableRoot = Resolve-AgentTrustedRoot -Path $durableRoot -Kind durable-state `
            -RepositoryRoot $repoRoot -Create
        $script:leaseRoot = Resolve-AgentTrustedRoot -Path $leaseRoot -Kind lease `
            -RepositoryRoot $repoRoot -DisallowedRoots $durableRoot -Create
        $script:context = Get-AgentDurableStateContext -DurableStateRoot $durableRoot `
            -RepositoryIdentity $identity -Role reviewer -Create
    }

    It 'rejects relative, repository-contained, and overlapping roots' {
        { Resolve-AgentTrustedRoot -Path 'relative' -Kind lease -RepositoryRoot $repoRoot -Create } |
            Should -Throw
        { Resolve-AgentTrustedRoot -Path (Join-Path $repoRoot '.state') -Kind lease -RepositoryRoot $repoRoot -Create } |
            Should -Throw
        { Resolve-AgentTrustedRoot -Path (Join-Path $durableRoot 'nested') -Kind lease `
                -RepositoryRoot $repoRoot -DisallowedRoots $durableRoot -Create } | Should -Throw
    }

    It 'keys work leases by verified repository, PR, and role without path input' {
        $reviewer = Enter-AgentWorkLease -LeaseRoot $leaseRoot -RepositoryIdentity $identity `
            -PullRequestId 104 -Role reviewer -TimeoutMilliseconds 0
        try {
            $contended = Enter-AgentWorkLease -LeaseRoot $leaseRoot -RepositoryIdentity $identity `
                -PullRequestId 104 -Role reviewer -TimeoutMilliseconds 100
            $otherRole = Enter-AgentWorkLease -LeaseRoot $leaseRoot -RepositoryIdentity $identity `
                -PullRequestId 104 -Role review-handler -TimeoutMilliseconds 0
            try {
                $reviewer.Acquired | Should -BeTrue
                $contended.Acquired | Should -BeFalse
                $contended.Reason | Should -Be 'lease-contended'
                $otherRole.Acquired | Should -BeTrue
                (Split-Path -Leaf $reviewer.Path) | Should -Match '^[0-9a-f]{64}\.lease$'
            }
            finally { Exit-AgentLock $otherRole.Stream }
        }
        finally { Exit-AgentLock $reviewer.Stream }
    }

    It 'releases the work lease after durable-state contention' {
        $heldState = Enter-AgentDurableStateLock -Context $context -TimeoutMilliseconds 0
        try {
            $run = Invoke-AgentWithWorkAuthority -LeaseRoot $leaseRoot -DurableContext $context `
                -RepositoryIdentity $identity -PullRequestId 104 -Role reviewer `
                -TimeoutMilliseconds 100 -Action { throw 'must not run' }
            $run.Acquired | Should -BeFalse
            $run.Reason | Should -Be 'state-contended'
        }

        finally { Exit-AgentLock $heldState.Stream }

        $retry = Enter-AgentWorkLease -LeaseRoot $leaseRoot -RepositoryIdentity $identity `
            -PullRequestId 104 -Role reviewer -TimeoutMilliseconds 0
        try { $retry.Acquired | Should -BeTrue }
        finally { Exit-AgentLock $retry.Stream }
    }

    It 'holds manual lease and state authority across actions until process teardown' {
        $lease = Enter-AgentWorkLease -LeaseRoot $leaseRoot -RepositoryIdentity $identity `
            -PullRequestId 104 -Role reviewer -TimeoutMilliseconds 0
        $stateLock = Enter-AgentDurableStateLock -Context $context -TimeoutMilliseconds 0
        $module = Get-Module DevPilot.AgentHarness
        $executionKey = Get-AgentExecutionKey -RepositoryIdentity $identity -PullRequestId 104 -Role reviewer
        & $module {
            param($Key, $Lease, $StateLock)
            $script:AgentManualAuthorities[$Key] = @{
                Lease = $Lease; StateLock = $StateLock; KeyHash = $Lease.KeyHash; OperatorContext = 'manual'
            }
        } $executionKey $lease $stateLock
        try {
            $first = Invoke-AgentWithWorkAuthority -LeaseRoot $leaseRoot -DurableContext $context `
                -RepositoryIdentity $identity -PullRequestId 104 -Role reviewer -Action { 'first' }
            $second = Invoke-AgentWithWorkAuthority -LeaseRoot $leaseRoot -DurableContext $context `
                -RepositoryIdentity $identity -PullRequestId 104 -Role reviewer -Action { 'second' }
            $first.Value | Should -Be 'first'
            $second.Value | Should -Be 'second'
            {
                $stream = [IO.File]::Open($lease.Path, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
                $stream.Dispose()
            } | Should -Throw
        }
        finally {
            Exit-AgentManualDispatchAuthority
        }
        $released = [IO.File]::Open($lease.Path, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        $released.Dispose()
    }

    It 'acknowledges only a nonce-bound manual cancellation request' {
        $lease = Enter-AgentWorkLease -LeaseRoot $leaseRoot -RepositoryIdentity $identity `
            -PullRequestId 104 -Role reviewer -TimeoutMilliseconds 0
        $stateLock = Enter-AgentDurableStateLock -Context $context -TimeoutMilliseconds 0
        $dispatchId = [Guid]::NewGuid().ToString('D')
        $nonce = New-AgentNonce
        $requestPath = Join-Path $context.RoleRoot 'cancel.requested.json'
        $ackPath = Join-Path $context.RoleRoot 'cancel.acknowledged.json'
        $executionKey = Get-AgentExecutionKey -RepositoryIdentity $identity -PullRequestId 104 -Role reviewer
        $module = Get-Module DevPilot.AgentHarness
        & $module {
            param($Key, $Lease, $StateLock, $DispatchId, $Nonce, $RequestPath, $AckPath)
            $script:AgentManualAuthorities[$Key] = @{
                Lease = $Lease; StateLock = $StateLock; OperatorContext = ''
                DispatchId = $DispatchId; CancellationNonce = $Nonce
                CancellationRequestPath = $RequestPath
                CancellationAcknowledgementPath = $AckPath
            }
        } $executionKey $lease $stateLock $dispatchId $nonce $requestPath $ackPath
        try {
            @{
                schemaVersion = 1; operation = 'cancel'; dispatchId = $dispatchId
                nonce = ('f' * 36)
            } | ConvertTo-Json -Compress | Set-Content -LiteralPath $requestPath -Encoding utf8NoBOM
            if (-not $IsWindows) {
                # Mirror the production cancellation-request writer
                # (Stop-BrokerChild in Invoke-DevPilotAgentDispatch.ps1), which
                # always chmods the request file owner-only before the broker
                # ever reads it. Leaving the default umask permissions here
                # would make Assert-AgentTrustedFile's -Private check reject
                # the file for unsafe permissions before the nonce mismatch is
                # ever evaluated, masking the manifest-binding assertion below.
                [IO.File]::SetUnixFileMode($requestPath,
                    [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite)
            }
            { Test-AgentManualCancellationRequested -RepositoryIdentity $identity `
                    -PullRequestId 104 -Role reviewer } | Should -Throw '*manifest binding*'
            Test-Path -LiteralPath $ackPath | Should -BeFalse

            @{
                schemaVersion = 1; operation = 'cancel'; dispatchId = $dispatchId; nonce = $nonce
            } | ConvertTo-Json -Compress | Set-Content -LiteralPath $requestPath -Encoding utf8NoBOM
            if (-not $IsWindows) {
                [IO.File]::SetUnixFileMode($requestPath,
                    [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite)
            }
            Test-AgentManualCancellationRequested -RepositoryIdentity $identity `
                -PullRequestId 104 -Role reviewer | Should -BeTrue
            $ack = Get-Content -LiteralPath $ackPath -Raw | ConvertFrom-Json -AsHashtable
            $ack.dispatchId | Should -BeExactly $dispatchId
            $ack.nonce | Should -BeExactly $nonce
            $ack.processId | Should -Be $PID
        }
        finally { Exit-AgentManualDispatchAuthority }
    }

    It 'classifies natural, cooperative, forced, and failed cancellation truthfully' {
        $natural = Get-AgentCancellationOutcome -AcknowledgementPresent $false `
            -AuthenticatedAcknowledgement $false -TreeExitedDuringGrace $true `
            -ForcedContainmentSucceeded $false
        $natural.Operation | Should -Be 'completed'
        $natural.HandleReleaseObserved | Should -BeTrue

        $cooperative = Get-AgentCancellationOutcome -AcknowledgementPresent $true `
            -AuthenticatedAcknowledgement $true -TreeExitedDuringGrace $true `
            -ForcedContainmentSucceeded $false
        $cooperative.Result | Should -Be 'cancelled-cooperative'
        $cooperative.HandleReleaseObserved | Should -BeTrue

        $forced = Get-AgentCancellationOutcome -AcknowledgementPresent $true `
            -AuthenticatedAcknowledgement $false -TreeExitedDuringGrace $false `
            -ForcedContainmentSucceeded $true
        $forced.Result | Should -Be 'cancelled-forced'
        $forced.HandleReleaseObserved | Should -BeTrue

        $failed = Get-AgentCancellationOutcome -AcknowledgementPresent $true `
            -AuthenticatedAcknowledgement $false -TreeExitedDuringGrace $false `
            -ForcedContainmentSucceeded $false
        $failed.Operation | Should -Be 'rejected'
        $failed.Result | Should -Be 'termination-failed'
        $failed.HandleReleaseObserved | Should -BeFalse
    }

    It 'authenticates lease contention over the startup pipe and releases no unacquired handle' {
        $policy = [ordered]@{
            schemaVersion = 1
            repositoryIdentity = @{ key = $identity.key; verified = $true }
            role = 'reviewer'
            capabilities = @()
            mandatoryDenies = @('EnableApprovalVote')
            configSnapshotSha256 = ('a' * 64)
        }
        $pipeName = New-AgentPipeName
        $runtimeRoot = Join-Path $suiteRoot 'manual-runtime'
        New-Item -ItemType Directory -Path $runtimeRoot | Out-Null
        $manifestPath = Join-Path $runtimeRoot 'dispatch-manifest.json'
        @{
            schemaVersion = 1
            dispatchId = [Guid]::NewGuid().ToString('D')
            role = 'reviewer'
            repositoryKey = $identity.key
            pullRequestId = 104
            capabilityPolicyDigest = Get-AgentCanonicalDigest $policy
            policy = $policy
            startupPipe = $pipeName
            runtimeRoot = $runtimeRoot
            prStateFingerprintSourceCommit = ('a' * 40)
        } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $manifestPath -Encoding utf8NoBOM
        $held = Enter-AgentWorkLease -LeaseRoot $leaseRoot -RepositoryIdentity $identity `
            -PullRequestId 104 -Role reviewer -TimeoutMilliseconds 0
        $pipe = [IO.Pipes.NamedPipeServerStream]::new($pipeName, [IO.Pipes.PipeDirection]::In, 1,
            [IO.Pipes.PipeTransmissionMode]::Byte,
            [IO.Pipes.PipeOptions]::Asynchronous -bor [IO.Pipes.PipeOptions]::CurrentUserOnly,
            4096, 4096)
        try {
            $connection = $pipe.WaitForConnectionAsync()
            {
                Enter-AgentManualDispatchStartup -ManifestPath $manifestPath `
                    -RepositoryIdentity $identity -DurableContext $context -LeaseRoot $leaseRoot `
                    -Role reviewer -EventLogPath (Join-Path $runtimeRoot 'events.jsonl') `
                    -BoundCapabilities @{ EnableApprovalVote = $false }
            } | Should -Throw '*lease-contended*'
            $connection.GetAwaiter().GetResult()
            $reader = [IO.StreamReader]::new($pipe, [Text.UTF8Encoding]::new($false, $true))
            $response = $reader.ReadLine() | ConvertFrom-Json -AsHashtable
            $response.operation | Should -BeExactly 'rejected'
            $response.code | Should -BeExactly 'already-running'
            $response.detail | Should -BeExactly 'lease-contended'
        }
        finally {
            $pipe.Dispose()
            Exit-AgentLock $held.Stream
        }
    }

    It 'removes only a validated per-draft residue tree' {
        $manualRoot = Join-Path $suiteRoot 'manual-dispatch'
        $draft = Join-Path $manualRoot ([Guid]::NewGuid().ToString('D'))
        New-Item -ItemType Directory -Path (Join-Path $draft 'runtime\config') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $draft 'runtime\dispatch-manifest.json') -Value '{}'
        Set-Content -LiteralPath (Join-Path $draft 'runtime\config\agent.config.snapshot.json') -Value '{}'

        Remove-AgentContainedDirectory -Path $draft -AllowedRoot $manualRoot `
            -LeafPattern '^[0-9a-f-]{36}$'
        Test-Path -LiteralPath $draft | Should -BeFalse
        { Remove-AgentContainedDirectory -Path $suiteRoot -AllowedRoot $manualRoot -LeafPattern '.*' } |
            Should -Throw '*Refusing to remove*'
    }

    It 'restores owner-write only after validation and removes Unix 0500 residue' -Skip:$IsWindows {
        foreach ($leaf in @([Guid]::NewGuid().ToString('D'), [Guid]::NewGuid().ToString('D'))) {
            $manualRoot = Join-Path $suiteRoot "manual-$leaf"
            $draft = Join-Path $manualRoot $leaf
            $nested = Join-Path $draft 'runtime'
            New-Item -ItemType Directory -Path $nested -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $nested 'snapshot.json') -Value '{}'
            [IO.File]::SetUnixFileMode($nested,
                [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserExecute)
            [IO.File]::SetUnixFileMode($draft,
                [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserExecute)
            Remove-AgentContainedDirectory -Path $draft -AllowedRoot $manualRoot `
                -LeafPattern '^[0-9a-f-]{36}$'
            Test-Path -LiteralPath $draft | Should -BeFalse
        }
    }

    It 'rejects linked trusted roots and descriptor permission tampering on Unix' -Skip:$IsWindows {
        $target = Join-Path $suiteRoot 'target'
        New-Item -ItemType Directory -Path $target | Out-Null
        [IO.File]::SetUnixFileMode($target,
            [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite -bor [IO.UnixFileMode]::UserExecute)
        $link = Join-Path $suiteRoot 'linked'
        New-Item -ItemType SymbolicLink -Path $link -Target $target | Out-Null
        { Resolve-AgentTrustedRoot -Path $link -Kind watch-state -RepositoryRoot $repoRoot } |
            Should -Throw '*link or reparse point*'
        { Resolve-AgentTrustedRoot -Path (Join-Path $link 'substituted') -Kind watch-state `
                -RepositoryRoot $repoRoot -Create } | Should -Throw '*link or reparse point*'

        $descriptor = Join-Path $suiteRoot 'descriptor.json'
        Set-Content -LiteralPath $descriptor -Value '{}' -Encoding utf8NoBOM
        [IO.File]::SetUnixFileMode($descriptor,
            [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite -bor [IO.UnixFileMode]::GroupWrite)
        { Assert-AgentTrustedFile -Path $descriptor -AllowedRoot $suiteRoot -Private } |
            Should -Throw '*unsafe Unix permissions*'
    }

    It 'serializes same repository and role while allowing another role' {
        $reviewer = Enter-AgentDurableStateLock -Context $context -TimeoutMilliseconds 0
        $handlerContext = Get-AgentDurableStateContext -DurableStateRoot $durableRoot `
            -RepositoryIdentity $identity -Role review-handler -Create
        try {
            (Enter-AgentDurableStateLock -Context $context -TimeoutMilliseconds 100).Reason |
                Should -Be 'state-contended'
            $handler = Enter-AgentDurableStateLock -Context $handlerContext -TimeoutMilliseconds 0
            try { $handler.Acquired | Should -BeTrue }
            finally { Exit-AgentLock $handler.Stream }
        }
        finally { Exit-AgentLock $reviewer.Stream }
    }

    It 'atomically advances generations and preserves record bindings' {
        $lock = Enter-AgentDurableStateLock -Context $context -TimeoutMilliseconds 0
        try {
            $written = Set-AgentDurableRecords -Context $context -Records @{
                '104' = @{ sourceCommit = ('a' * 40); delivered = $true }
            }

            $written.generation | Should -Be 1
            $read = Read-AgentDurableState -Context $context
            $read.records['104'].sourceCommit | Should -Be ('a' * 40)
            $read.repositoryKey | Should -Be $identity.key
            $read.role | Should -Be 'reviewer'
        }
        finally { Exit-AgentLock $lock.Stream }
    }

    It 'preserves an exact manual partial-delivery artifact across draft cleanup and restart' {
        $reviewerPath = Resolve-Path "$PSScriptRoot\..\src\Agents\reviewer\Start-ReviewerAgent.ps1"
        $reviewerSource = Get-Content -LiteralPath $reviewerPath -Raw
        $reviewerSource | Should -Match "Join-Path \`$script:ReviewerDurableContext\.RoleRoot 'pending-artifacts'"
        $reviewerSource | Should -Match 'deliveryPending\s+= \$true[\s\S]+Set-AgentDurableRecords[\s\S]+Invoke-ReviewerDelivery'
        $pendingRoot = Join-Path $context.RoleRoot 'pending-artifacts'
        New-Item -ItemType Directory -Path $pendingRoot | Out-Null
        if (-not $IsWindows) {
            [IO.File]::SetUnixFileMode($pendingRoot,
                [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite -bor [IO.UnixFileMode]::UserExecute)
        }
        $artifactPath = Join-Path $pendingRoot 'manual-sealed.json'
        $sealedBytes = [Text.UTF8Encoding]::new($false).GetBytes(
            '{"manifestJson":"exact-partial-plan","signature":"sealed"}')
        [IO.File]::WriteAllBytes($artifactPath, $sealedBytes)
        $sealedHash = (Get-FileHash -LiteralPath $artifactPath -Algorithm SHA256).Hash
        $manualRoot = Join-Path $suiteRoot 'manual-dispatch'
        $draftRoot = Join-Path $manualRoot ([Guid]::NewGuid().ToString('D'))
        New-Item -ItemType Directory -Path (Join-Path $draftRoot 'runtime') -Force | Out-Null

        $lock = Enter-AgentDurableStateLock -Context $context -TimeoutMilliseconds 0
        try {
            Set-AgentDurableRecords -Context $context -Records @{
                '104' = @{
                    sourceCommit = ('a' * 40)
                    deliveryPending = $true
                    pendingCapabilities = @('comments')
                    artifactPath = $artifactPath
                }
            } | Out-Null
        }
        finally { Exit-AgentLock $lock.Stream }

        Remove-AgentContainedDirectory -Path $draftRoot -AllowedRoot $manualRoot `
            -LeafPattern '^[0-9a-f-]{36}$'
        $restarted = Get-AgentDurableRecordsSnapshot -Context $context
        $restarted['104'].deliveryPending | Should -BeTrue
        $restarted['104'].artifactPath | Should -BeExactly $artifactPath
        (Get-FileHash -LiteralPath $artifactPath -Algorithm SHA256).Hash |
            Should -BeExactly $sealedHash

        $restarted['104'].deliveryPending = $false
        $lock = Enter-AgentDurableStateLock -Context $context -TimeoutMilliseconds 0
        try { Set-AgentDurableRecords -Context $context -Records $restarted | Out-Null }
        finally { Exit-AgentLock $lock.Stream }
        Remove-Item -LiteralPath $artifactPath -Force
        Test-Path -LiteralPath $artifactPath | Should -BeFalse
    }

    It 'provides a lock-free scheduling snapshot while preserving authoritative contention' {
        $lock = Enter-AgentDurableStateLock -Context $context -TimeoutMilliseconds 0
        try {
            Set-AgentDurableRecords -Context $context -Records @{
                '104' = @{ sourceCommit = ('a' * 40); at = '2026-09-03T00:00:00Z' }
            } | Out-Null
            $snapshot = Get-AgentDurableRecordsSnapshot -Context $context
            $snapshot['104'].sourceCommit | Should -Be ('a' * 40)
            (Enter-AgentDurableStateLock -Context $context -TimeoutMilliseconds 0).Reason |
                Should -Be 'state-contended'
        }
        finally { Exit-AgentLock $lock.Stream }
    }

    It 'reads lock-free snapshots while Windows atomically replaces the state file' -Skip:(-not $IsWindows) {
        $lock = Enter-AgentDurableStateLock -Context $context -TimeoutMilliseconds 0
        $writer = $null
        try {
            Set-AgentDurableRecords -Context $context -Records @{
                '104' = @{ sourceCommit = ('a' * 40); sequence = 0 }
            } | Out-Null
            $failures = [Collections.Generic.List[string]]::new()
            $writer = Start-Job -ArgumentList $context.StatePath, $context.RepositoryKey, $context.RepositoryIdentity -ScriptBlock {
                param($statePath, $repositoryKey, $repositoryIdentity)
                $ErrorActionPreference = 'Stop'
                1..150 | ForEach-Object {
                    $payload = [ordered]@{
                        schemaVersion = 2; generation = $_; repositoryKey = $repositoryKey
                        repositoryIdentity = $repositoryIdentity; role = 'reviewer'
                        records = @{ '104' = @{ sourceCommit = ('a' * 40); sequence = $_ } }
                        migrationReceipts = @{}; updatedAtUtc = [DateTime]::UtcNow.ToString('o')
                    } | ConvertTo-Json -Compress -Depth 20
                    $temp = "$statePath.writer-$PID-$_"
                    [IO.File]::WriteAllText($temp, $payload, [Text.UTF8Encoding]::new($false))
                    $moved = $false
                    for ($attempt = 0; $attempt -lt 20 -and -not $moved; $attempt++) {
                        try {
                            [IO.File]::Move($temp, $statePath, $true)
                            $moved = $true
                        }
                        catch [UnauthorizedAccessException] {
                            if ($attempt -eq 19) { throw }
                            Start-Sleep -Milliseconds 5
                        }
                        catch [IO.IOException] {
                            if ($attempt -eq 19) { throw }
                            Start-Sleep -Milliseconds 5
                        }
                    }
                }
            }
            $reads = 0
            while ($writer.State -in @('NotStarted', 'Running')) {
                $records = Get-AgentDurableRecordsSnapshot -Context $context
                $reads++
                if (-not $records.ContainsKey('104') -or
                    [string]$records['104'].sourceCommit -ne ('a' * 40)) {
                    $failures.Add("invalid snapshot at read $reads")
                }
            }
            $writer | Wait-Job | Receive-Job -ErrorAction Stop
            $writer.State | Should -Be 'Completed'
            $reads | Should -BeGreaterThan 0
            $failures | Should -BeNullOrEmpty
        }
        finally {
            if ($writer) { Remove-Job -Job $writer -Force -ErrorAction SilentlyContinue }
            Exit-AgentLock $lock.Stream
        }
    }

    It 'fails closed on malformed durable state instead of returning empty records' {
        '{"schemaVersion":2,"records":' |
            Set-Content -LiteralPath $context.StatePath -Encoding utf8NoBOM
        { Get-AgentDurableRecordsSnapshot -Context $context } | Should -Throw
    }

    It 'initializes and verifies explicitly reconciled empty state' {
        $lock = Enter-AgentDurableStateLock -Context $context -TimeoutMilliseconds 0
        try {
            $written = Initialize-AgentDurableState -Context $context -Records @{} `
                -ReceiptKey 'reconciled-empty' -ReceiptSha256 ('e' * 64)
            $written.records.Count | Should -Be 0
            (Read-AgentDurableState -Context $context).migrationReceipts.ContainsKey('reconciled-empty') |
                Should -BeTrue
            Test-Path -LiteralPath $context.InitializedPath -PathType Leaf | Should -BeTrue
        }
        finally { Exit-AgentLock $lock.Stream }
    }

    It 'recovers an installed generation and removes a stale journal' {
        $lock = Enter-AgentDurableStateLock -Context $context -TimeoutMilliseconds 0
        try {
            $written = Set-AgentDurableRecords -Context $context -Records @{ '104' = @{ delivered = $true } }
            $bytes = [IO.File]::ReadAllBytes($context.StatePath)
            $journal = @{
                schemaVersion = 1
                previousGeneration = 0
                intendedGeneration = $written.generation
                payloadLength = $bytes.Length
                payloadSha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
                tempName = ''
                backupName = ''
                backupLength = 0
                backupSha256 = ''
                phase = 'prepared'
            }
            $journal | ConvertTo-Json -Compress | Set-Content -LiteralPath $context.JournalPath -Encoding utf8NoBOM
            Repair-AgentDurableState -Context $context
            Test-Path -LiteralPath $context.JournalPath | Should -BeFalse
            (Read-AgentDurableState -Context $context).generation | Should -Be 1
        }
        finally { Exit-AgentLock $lock.Stream }
    }

    It 'records one idempotent migration receipt and refuses conflicting state' {
        $lock = Enter-AgentDurableStateLock -Context $context -TimeoutMilliseconds 0
        try {
            $first = Initialize-AgentDurableState -Context $context -Records @{
                '104' = @{ sourceCommit = ('b' * 40); deliveryPending = $false }
            } -ReceiptKey 'legacy-reviewer' -ReceiptSha256 ('c' * 64)
            $again = Initialize-AgentDurableState -Context $context -Records @{} `
                -ReceiptKey 'legacy-reviewer' -ReceiptSha256 ('c' * 64)
            $again.generation | Should -Be $first.generation
            { Initialize-AgentDurableState -Context $context -Records @{} `
                    -ReceiptKey 'other' -ReceiptSha256 ('d' * 64) } | Should -Throw
        }
        finally { Exit-AgentLock $lock.Stream }
    }
}
