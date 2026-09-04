BeforeAll {
    Import-Module "$PSScriptRoot\..\src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1" -Force
    $script:brokerPath = (Resolve-Path "$PSScriptRoot\..\tools\Invoke-DevPilotAgentDispatch.ps1").Path
    $script:harnessPath = (Resolve-Path "$PSScriptRoot\..\src\DevPilot.AgentHarness\DevPilot.AgentHarness.psm1").Path
    $script:identity = @{ key = 'v1:github:contoso/widgets'; verified = $true }
    $script:commit = 'a' * 40

    function New-TestRoots {
        $suite = Join-Path $TestDrive ([Guid]::NewGuid().ToString('N'))
        $lad = Join-Path $suite 'lad'
        New-Item -ItemType Directory -Path $lad -Force | Out-Null
        $env:LOCALAPPDATA = $lad
        $repoRoot = Join-Path $suite 'repo'
        New-Item -ItemType Directory -Path $repoRoot -Force | Out-Null
        return @{ Suite = $suite; RepoRoot = $repoRoot }
    }

    function Write-OverrideFile {
        param([string]$Path, [hashtable]$Record)
        New-Item -ItemType Directory -Path (Split-Path $Path -Parent) -Force | Out-Null
        [IO.File]::WriteAllText($Path, (ConvertTo-AgentCanonicalJson $Record), [Text.UTF8Encoding]::new($false))
    }
}

Describe 'capability-override root hardening' {
    It 'exports every new PR2 primitive at module scope and keeps mutation-resistant projections' {
        foreach ($name in @(
                'Get-AgentDefaultCapabilityOverrideRoot', 'ConvertTo-AgentCanonicalEpochSeconds',
                'Get-AgentWorktreeIdentity', 'Read-AgentStableFile', 'ConvertFrom-AgentTrustedCapabilityJson',
                'Resolve-AgentEffectiveCapabilitySettings', 'Resolve-AgentCapabilityPolicyPartition',
                'Enter-AgentCapabilityOverrideLock')) {
            Get-Command $name -Module DevPilot.AgentHarness | Should -Not -BeNullOrEmpty
        }
        $manifestContent = Get-Content -LiteralPath (Resolve-Path "$PSScriptRoot\..\src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1").Path -Raw
        foreach ($name in @(
                'Get-AgentDefaultCapabilityOverrideRoot', 'ConvertTo-AgentCanonicalEpochSeconds',
                'Get-AgentWorktreeIdentity', 'Read-AgentStableFile', 'ConvertFrom-AgentTrustedCapabilityJson',
                'Resolve-AgentEffectiveCapabilitySettings', 'Resolve-AgentCapabilityPolicyPartition',
                'Enter-AgentCapabilityOverrideLock')) {
            $manifestContent | Should -Match ([regex]::Escape("'$name'"))
        }
    }

    It 'never accepts a forwarded root and stays disjoint from sibling default roots' {
        $roots = New-TestRoots
        $default = Get-AgentDefaultCapabilityOverrideRoot
        $default | Should -Match '\\DevPilot\\capability-overrides\\v1$'
        $siblings = @((Get-AgentDefaultDurableStateRoot), (Get-AgentDefaultLeaseRoot), (Get-AgentDefaultWatchStateRoot))
        foreach ($sibling in $siblings) {
            Test-AgentPathWithin -Path $default -Root $sibling | Should -BeFalse
            Test-AgentPathWithin -Path $sibling -Root $default | Should -BeFalse
        }
        (Get-Command Resolve-AgentEffectiveCapabilitySettings).Parameters.Keys | Should -Not -Contain 'CapabilityOverrideRoot'
        (Get-Command Resolve-AgentEffectiveCapabilitySettings).Parameters.Keys | Should -Not -Contain 'Root'
    }

    It 'rejects a reparse/symlink capability-override root' {
        if (-not $IsWindows) {
            $roots = New-TestRoots
            $real = Join-Path $roots.Suite 'real-root'
            New-Item -ItemType Directory -Path $real -Force | Out-Null
            $linkParent = Split-Path (Get-AgentDefaultCapabilityOverrideRoot) -Parent
            New-Item -ItemType Directory -Path $linkParent -Force | Out-Null
            $linked = Get-AgentDefaultCapabilityOverrideRoot
            New-Item -ItemType SymbolicLink -Path $linked -Target $real -Force | Out-Null
            { Resolve-AgentEffectiveCapabilitySettings -RepositoryIdentity $identity -RepositoryRoot $roots.RepoRoot `
                    -PullRequestId 1 -CurrentSourceCommit $commit } | Should -Throw '*link or reparse point*'
        }
        else {
            Set-ItResult -Skipped -Because 'symlink containment for the Windows ACL/reparse path is covered by Resolve-AgentTrustedRoot/Assert-AgentPathHasNoLinks unit tests already in DurableState.Tests.ps1; this suite exercises the Unix path directly'
        }
    }
}

Describe 'capability-override settings schema' {
    It 'requires and forbids the exact fields per scope' {
        $cases = @(
            @{ Scope = 'machine'; Record = @{ schemaVersion = 1; settings = @{} } ; ShouldThrow = $false }
            @{ Scope = 'machine'; Record = @{ schemaVersion = 1; settings = @{}; repositoryKey = 'v1:github:x/y' }; ShouldThrow = $true }
            @{ Scope = 'user'; Record = @{ schemaVersion = 1; settings = @{}; worktreeId = ('0' * 64) }; ShouldThrow = $true }
            @{ Scope = 'repo-worktree'; Record = @{ schemaVersion = 1; settings = @{} }; ShouldThrow = $true }
            @{
                Scope = 'repo-worktree'
                Record = @{ schemaVersion = 1; settings = @{}; repositoryKey = 'v1:github:x/y'; worktreeId = ('0' * 64) }
                ShouldThrow = $false
            }
            @{
                Scope = 'repo-worktree'
                Record = @{
                    schemaVersion = 1; settings = @{}; repositoryKey = 'v1:github:x/y'; worktreeId = ('0' * 64)
                    pullRequestId = 1
                }
                ShouldThrow = $true
            }
            @{ Scope = 'pr'; Record = @{ schemaVersion = 1; settings = @{}; repositoryKey = 'v1:github:x/y'; worktreeId = ('0' * 64) }; ShouldThrow = $true }
            @{
                Scope = 'pr'
                Record = @{
                    schemaVersion = 1; settings = @{}; repositoryKey = 'v1:github:x/y'; worktreeId = ('0' * 64)
                    pullRequestId = 1; sourceCommit = ('a' * 40); expiresAtUtc = 4102444800
                }
                ShouldThrow = $false
            }
        )
        foreach ($case in $cases) {
            $bytes = [Text.Encoding]::UTF8.GetBytes(($case.Record | ConvertTo-Json -Compress -Depth 10))
            if ($case.ShouldThrow) {
                { ConvertFrom-AgentTrustedCapabilityJson -Bytes $bytes -SourceScope $case.Scope -AllowedCapabilities @('EnableThreadReplies') } |
                    Should -Throw '*capability-settings-invalid*'
            }
            else {
                { ConvertFrom-AgentTrustedCapabilityJson -Bytes $bytes -SourceScope $case.Scope -AllowedCapabilities @('EnableThreadReplies') } |
                    Should -Not -Throw
            }
        }
    }

    It 'accepts only inherit/off values and only recognized, non-delegable capability keys' {
        $allowed = @('EnableThreadReplies', 'EnableSummaryComment')
        { ConvertFrom-AgentTrustedCapabilityJson -Bytes ([Text.Encoding]::UTF8.GetBytes('{"schemaVersion":1,"settings":{"EnableThreadReplies":"inherit"}}')) -SourceScope machine -AllowedCapabilities $allowed } |
            Should -Not -Throw
        { ConvertFrom-AgentTrustedCapabilityJson -Bytes ([Text.Encoding]::UTF8.GetBytes('{"schemaVersion":1,"settings":{"EnableThreadReplies":"off"}}')) -SourceScope machine -AllowedCapabilities $allowed } |
            Should -Not -Throw
        { ConvertFrom-AgentTrustedCapabilityJson -Bytes ([Text.Encoding]::UTF8.GetBytes('{"schemaVersion":1,"settings":{"EnableThreadReplies":"on"}}')) -SourceScope machine -AllowedCapabilities $allowed } |
            Should -Throw '*capability-settings-invalid*'
        { ConvertFrom-AgentTrustedCapabilityJson -Bytes ([Text.Encoding]::UTF8.GetBytes('{"schemaVersion":1,"settings":{"EnableApprovalVote":"off"}}')) -SourceScope machine -AllowedCapabilities $allowed } |
            Should -Throw '*not a recognized manually-selectable capability*'
        { ConvertFrom-AgentTrustedCapabilityJson -Bytes ([Text.Encoding]::UTF8.GetBytes('{"schemaVersion":1,"settings":{"totallyMadeUp":"off"}}')) -SourceScope machine -AllowedCapabilities $allowed } |
            Should -Throw '*not a recognized manually-selectable capability*'
    }

    It 'rejects a secret-shaped capability key even when otherwise well-formed' {
        $secretKey = ('a1b2c3' * 6)
        $bytes = [Text.Encoding]::UTF8.GetBytes(('{"schemaVersion":1,"settings":{"' + $secretKey + '":"off"}}'))
        { ConvertFrom-AgentTrustedCapabilityJson -Bytes $bytes -SourceScope machine -AllowedCapabilities @($secretKey) } |
            Should -Throw '*secret-shaped*'
        # A clearly non-secret-shaped, allow-listed capability name of similar length is unaffected.
        { ConvertFrom-AgentTrustedCapabilityJson -Bytes ([Text.Encoding]::UTF8.GetBytes('{"schemaVersion":1,"settings":{"EnableThreadReplies":"off"}}')) `
                -SourceScope machine -AllowedCapabilities @('EnableThreadReplies') } | Should -Not -Throw
    }

    It 'rejects raw duplicate and case-collision object keys before hashtable conversion' {
        $dup = [Text.Encoding]::UTF8.GetBytes('{"schemaVersion":1,"settings":{},"schemaVersion":1}')
        { ConvertFrom-AgentTrustedCapabilityJson -Bytes $dup -SourceScope machine -AllowedCapabilities @() } |
            Should -Throw "*Duplicate property*"
        $collide = [Text.Encoding]::UTF8.GetBytes('{"schemaVersion":1,"Settings":{},"settings":{}}')
        { ConvertFrom-AgentTrustedCapabilityJson -Bytes $collide -SourceScope machine -AllowedCapabilities @() } |
            Should -Throw '*collides case-insensitively*'
        $nestedCollide = [Text.Encoding]::UTF8.GetBytes('{"schemaVersion":1,"settings":{"EnableThreadReplies":"off","enableThreadReplies":"off"}}')
        { ConvertFrom-AgentTrustedCapabilityJson -Bytes $nestedCollide -SourceScope machine -AllowedCapabilities @('EnableThreadReplies') } |
            Should -Throw '*collides case-insensitively*'
    }

    It 'enforces byte, depth, element, and string bounds and fails closed' {
        $big = [Text.Encoding]::UTF8.GetBytes('{"schemaVersion":1,"settings":{},"pad":"' + ('x' * 70000) + '"}')
        { ConvertFrom-AgentTrustedCapabilityJson -Bytes $big -SourceScope machine -AllowedCapabilities @() } |
            Should -Throw '*exceeds the byte limit*'

        # Bounds are enforced by ConvertFrom-AgentTrustedCapabilityJson's own raw-shape pass, before
        # any schema check runs -- an otherwise-nonsensical document still fails with a bounds error,
        # not a schema error, proving the bounds check runs first and fails closed on its own.
        $deep = ('{"a":' * 10) + '1' + ('}' * 10)
        { ConvertFrom-AgentTrustedCapabilityJson -Bytes ([Text.Encoding]::UTF8.GetBytes($deep)) -SourceScope machine -AllowedCapabilities @() } |
            Should -Throw '*maximum nesting depth*'

        $manyProps = ((0..600) | ForEach-Object { "`"p$_`":1" }) -join ','
        { ConvertFrom-AgentTrustedCapabilityJson -Bytes ([Text.Encoding]::UTF8.GetBytes("{$manyProps}")) -SourceScope machine -AllowedCapabilities @() } |
            Should -Throw '*maximum element count*'

        $longString = '{"x":"' + ('y' * 5000) + '"}'
        { ConvertFrom-AgentTrustedCapabilityJson -Bytes ([Text.Encoding]::UTF8.GetBytes($longString)) -SourceScope machine -AllowedCapabilities @() } |
            Should -Throw '*maximum length*'
    }
}

Describe 'capability-override effective resolution' {
    It 'is byte/behavior equivalent to an unconfigured (PR1) store when nothing is persisted' {
        $roots = New-TestRoots
        $result = Resolve-AgentEffectiveCapabilitySettings -RepositoryIdentity $identity -RepositoryRoot $roots.RepoRoot `
            -PullRequestId 7 -CurrentSourceCommit $commit
        $result.Settings.Count | Should -Be 0
        $result.Provenance.Count | Should -Be 0
        $result.FileFingerprints.Count | Should -Be 4
        foreach ($fp in $result.FileFingerprints) { $fp.Exists | Should -BeFalse }
        $roleDescriptor = @{ capabilities = @('EnableThreadReplies', 'EnableSummaryComment'); mandatoryDenies = @('EnableApprovalVote') }
        $partition = Resolve-AgentCapabilityPolicyPartition -RoleDescriptor $roleDescriptor -PersistedNarrowing $result.Settings
        @($partition.capabilities | Sort-Object) | Should -BeExactly @($roleDescriptor.capabilities | Sort-Object)
        @($partition.mandatoryDenies | Sort-Object) | Should -BeExactly @($roleDescriptor.mandatoryDenies | Sort-Object)
    }

    It 'applies broad-to-narrow precedence where a narrower scope can only add more off, never restore on' {
        $roots = New-TestRoots
        $overrideRoot = Get-AgentDefaultCapabilityOverrideRoot
        Write-OverrideFile (Join-Path $overrideRoot 'machine.settings.v1.json') @{ schemaVersion = 1; settings = @{ EnableThreadReplies = 'off' } }
        Write-OverrideFile (Join-Path $overrideRoot 'user.settings.v1.json') @{ schemaVersion = 1; settings = @{ EnableSummaryComment = 'off' } }
        $repoKey = Get-AgentRepositoryIdentityKey -RepositoryIdentity $identity
        $worktreeId = Get-AgentWorktreeIdentity -RepositoryRoot $roots.RepoRoot
        $repoRootPath = Join-Path (Join-Path $overrideRoot 'repo') (Get-AgentSha256 -Text $repoKey)
        Write-OverrideFile (Join-Path $repoRootPath "$worktreeId.settings.v1.json") @{
            schemaVersion = 1; repositoryKey = $repoKey; worktreeId = $worktreeId
            settings = @{ EnableThreadReplies = 'inherit' }
        }
        $result = Resolve-AgentEffectiveCapabilitySettings -RepositoryIdentity $identity -RepositoryRoot $roots.RepoRoot `
            -PullRequestId 7 -CurrentSourceCommit $commit
        $result.Settings['EnableThreadReplies'] | Should -Be 'off'
        $result.Provenance['EnableThreadReplies'] | Should -Be 'machine'
        $result.Settings['EnableSummaryComment'] | Should -Be 'off'
        $result.Provenance['EnableSummaryComment'] | Should -Be 'user'
    }

    It 'keeps two worktrees of the same repository fully independent' {
        $roots = New-TestRoots
        $repoRootTwo = Join-Path $roots.Suite 'repo-second-worktree'
        New-Item -ItemType Directory -Path $repoRootTwo -Force | Out-Null
        $overrideRoot = Get-AgentDefaultCapabilityOverrideRoot
        $repoKey = Get-AgentRepositoryIdentityKey -RepositoryIdentity $identity
        $worktreeIdOne = Get-AgentWorktreeIdentity -RepositoryRoot $roots.RepoRoot
        $repoRootPath = Join-Path (Join-Path $overrideRoot 'repo') (Get-AgentSha256 -Text $repoKey)
        Write-OverrideFile (Join-Path $repoRootPath "$worktreeIdOne.settings.v1.json") @{
            schemaVersion = 1; repositoryKey = $repoKey; worktreeId = $worktreeIdOne
            settings = @{ EnableThreadReplies = 'off' }
        }
        $resultOne = Resolve-AgentEffectiveCapabilitySettings -RepositoryIdentity $identity -RepositoryRoot $roots.RepoRoot `
            -PullRequestId 7 -CurrentSourceCommit $commit
        $resultTwo = Resolve-AgentEffectiveCapabilitySettings -RepositoryIdentity $identity -RepositoryRoot $repoRootTwo `
            -PullRequestId 7 -CurrentSourceCommit $commit
        $resultOne.Settings.Contains('EnableThreadReplies') | Should -BeTrue
        $resultTwo.Settings.Contains('EnableThreadReplies') | Should -BeFalse
    }

    It 'fails the whole resolution closed on a stale PR-scope source commit' {
        $roots = New-TestRoots
        $overrideRoot = Get-AgentDefaultCapabilityOverrideRoot
        $repoKey = Get-AgentRepositoryIdentityKey -RepositoryIdentity $identity
        $worktreeId = Get-AgentWorktreeIdentity -RepositoryRoot $roots.RepoRoot
        $repoRootPath = Join-Path (Join-Path $overrideRoot 'repo') (Get-AgentSha256 -Text $repoKey)
        $staleCommit = 'b' * 40
        Write-OverrideFile (Join-Path (Join-Path $repoRootPath 'pr') "7-$($staleCommit.Substring(0,12)).settings.v1.json") @{
            schemaVersion = 1; repositoryKey = $repoKey; worktreeId = $worktreeId; pullRequestId = 7
            sourceCommit = $staleCommit; expiresAtUtc = 4102444800; settings = @{ EnableThreadReplies = 'off' }
        }
        # Renamed to match the CURRENT commit's short-SHA filename slot, but its content sourceCommit
        # still records the stale one -- full-SHA content is authoritative, not the display filename.
        Rename-Item -LiteralPath (Join-Path (Join-Path $repoRootPath 'pr') "7-$($staleCommit.Substring(0,12)).settings.v1.json") `
            -NewName "7-$($commit.Substring(0,12)).settings.v1.json"
        { Resolve-AgentEffectiveCapabilitySettings -RepositoryIdentity $identity -RepositoryRoot $roots.RepoRoot `
                -PullRequestId 7 -CurrentSourceCommit $commit } | Should -Throw '*capability-settings-stale*'
    }

    It 'fails the whole resolution closed on an expired PR-scope record' {
        $roots = New-TestRoots
        $overrideRoot = Get-AgentDefaultCapabilityOverrideRoot
        $repoKey = Get-AgentRepositoryIdentityKey -RepositoryIdentity $identity
        $worktreeId = Get-AgentWorktreeIdentity -RepositoryRoot $roots.RepoRoot
        $repoRootPath = Join-Path (Join-Path $overrideRoot 'repo') (Get-AgentSha256 -Text $repoKey)
        Write-OverrideFile (Join-Path (Join-Path $repoRootPath 'pr') "7-$($commit.Substring(0,12)).settings.v1.json") @{
            schemaVersion = 1; repositoryKey = $repoKey; worktreeId = $worktreeId; pullRequestId = 7
            sourceCommit = $commit; expiresAtUtc = 1000; settings = @{ EnableThreadReplies = 'off' }
        }
        { Resolve-AgentEffectiveCapabilitySettings -RepositoryIdentity $identity -RepositoryRoot $roots.RepoRoot `
                -PullRequestId 7 -CurrentSourceCommit $commit } | Should -Throw '*capability-settings-expired*'
    }

    It 'fails closed when a repo-worktree record is bound to a different repository or worktree' {
        $roots = New-TestRoots
        $overrideRoot = Get-AgentDefaultCapabilityOverrideRoot
        $repoKey = Get-AgentRepositoryIdentityKey -RepositoryIdentity $identity
        $worktreeId = Get-AgentWorktreeIdentity -RepositoryRoot $roots.RepoRoot
        $repoRootPath = Join-Path (Join-Path $overrideRoot 'repo') (Get-AgentSha256 -Text $repoKey)
        Write-OverrideFile (Join-Path $repoRootPath "$worktreeId.settings.v1.json") @{
            schemaVersion = 1; repositoryKey = 'v1:github:someone/else'; worktreeId = $worktreeId
            settings = @{ EnableThreadReplies = 'off' }
        }
        { Resolve-AgentEffectiveCapabilitySettings -RepositoryIdentity $identity -RepositoryRoot $roots.RepoRoot `
                -PullRequestId 7 -CurrentSourceCommit $commit } | Should -Throw '*identity binding does not match*'
    }
}

Describe 'capability-override advisory lock' {
    It 'is exclusive per capability-override root and releases cleanly' {
        $roots = New-TestRoots
        $first = Enter-AgentCapabilityOverrideLock -RepositoryRoot $roots.RepoRoot -TimeoutMilliseconds 200
        $first.Acquired | Should -BeTrue
        $second = Enter-AgentCapabilityOverrideLock -RepositoryRoot $roots.RepoRoot -TimeoutMilliseconds 200
        $second.Acquired | Should -BeFalse
        $second.Reason | Should -Be 'capability-override-contended'
        Exit-AgentLock $first.Stream
        $third = Enter-AgentCapabilityOverrideLock -RepositoryRoot $roots.RepoRoot -TimeoutMilliseconds 200
        $third.Acquired | Should -BeTrue
        Exit-AgentLock $third.Stream
    }
}

Describe 'broker and child-startup wiring' {
    It 'wires the effective resolver into the shared profile/describe builder, narrowing only' {
        $source = Get-Content -LiteralPath $brokerPath -Raw
        $helperBody = [regex]::Match($source, '(?s)function Get-BrokerCapabilityProfile \{.*?\n\}').Value
        $helperBody | Should -Match 'Resolve-AgentEffectiveCapabilitySettings'
        $helperBody | Should -Match 'Resolve-AgentCapabilityPolicyPartition'
        $describeBody = [regex]::Match($source, '(?s)function Invoke-Describe \{.*?\n\}').Value
        $describeBody | Should -Match 'ceilingCapabilities = \$profile\.CeilingCapabilities'
        $describeBody | Should -Match 'ceilingMandatoryDenies = \$profile\.CeilingMandatoryDenies'
    }

    It 'holds the capability-override lock across the child ready/proceed exchange' {
        $harnessSource = Get-Content -LiteralPath $harnessPath -Raw
        $startupBody = [regex]::Match($harnessSource, '(?s)function Enter-AgentManualDispatchStartup \{.*?\n\}').Value
        $lockIndex = $startupBody.IndexOf('Enter-AgentCapabilityOverrideLock')
        $liveCheckIndex = $startupBody.IndexOf('[policy-changed] Live capability settings')
        $readyIndex = $startupBody.IndexOf("operation = 'ready'")
        $releaseIndex = $startupBody.IndexOf('Exit-AgentLock $capabilityLock.Stream', $readyIndex)
        $lockIndex | Should -BeGreaterThan -1
        $liveCheckIndex | Should -BeGreaterThan $lockIndex
        $readyIndex | Should -BeGreaterThan $liveCheckIndex
        $releaseIndex | Should -BeGreaterThan $readyIndex
    }

    It 'independently recomputed startup attestation catches a narrowing applied after describe but before ready' {
        $roots = New-TestRoots
        $overrideRoot = Get-AgentDefaultCapabilityOverrideRoot
        $durableRoot = Resolve-AgentTrustedRoot -Path (Join-Path $roots.Suite 'durable') -Kind durable-state `
            -RepositoryRoot $roots.RepoRoot -Create
        $leaseRoot = Resolve-AgentTrustedRoot -Path (Join-Path $roots.Suite 'leases') -Kind lease `
            -RepositoryRoot $roots.RepoRoot -DisallowedRoots $durableRoot -Create
        $context = Get-AgentDurableStateContext -DurableStateRoot $durableRoot -RepositoryIdentity $identity -Role reviewer -Create
        $policy = [ordered]@{
            schemaVersion = 1
            repositoryIdentity = @{ key = $identity.key; verified = $true }
            role = 'reviewer'
            capabilities = @('EnableFindingComments', 'EnableSummaryComment')
            mandatoryDenies = @('EnableApprovalVote')
            ceilingCapabilities = @('EnableFindingComments', 'EnableSummaryComment')
            ceilingMandatoryDenies = @('EnableApprovalVote')
            configSnapshotSha256 = ('a' * 64)
        }
        $runtimeRoot = Join-Path $roots.Suite 'manual-runtime'
        New-Item -ItemType Directory -Path $runtimeRoot -Force | Out-Null
        $promptPath = Join-Path $runtimeRoot 'operator-context.txt'
        [IO.File]::WriteAllText($promptPath, 'do the review', [Text.UTF8Encoding]::new($false))
        $manifestPath = Join-Path $runtimeRoot 'dispatch-manifest.json'
        @{
            schemaVersion = 1
            dispatchId = [Guid]::NewGuid().ToString('D')
            role = 'reviewer'
            repositoryKey = $identity.key
            pullRequestId = 7
            capabilityPolicyDigest = Get-AgentCanonicalDigest $policy
            policy = $policy
            startupPipe = (New-AgentPipeName)
            runtimeRoot = $runtimeRoot
            operatorPromptPath = $promptPath
            prStateFingerprintSourceCommit = $commit
        } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $manifestPath -Encoding utf8NoBOM

        # Narrow AFTER the manifest/digest snapshot above (simulating "describe already happened")
        # but BEFORE the child's own startup re-verification runs.
        Write-OverrideFile (Join-Path $overrideRoot 'machine.settings.v1.json') @{
            schemaVersion = 1; settings = @{ EnableSummaryComment = 'off' }
        }

        # The live re-verification (capability lock + resolve + partition + digest compare) runs
        # BEFORE the pipe is ever opened, so this throws well ahead of any pipe-connect attempt --
        # no pipe server is needed to observe that 'ready' is never sent.
        { Enter-AgentManualDispatchStartup -ManifestPath $manifestPath -RepositoryIdentity $identity `
                -RepositoryRoot $roots.RepoRoot -DurableContext $context -LeaseRoot $leaseRoot `
                -Role reviewer -EventLogPath (Join-Path $runtimeRoot 'events.jsonl') `
                -BoundCapabilities @{ EnableFindingComments = $true; EnableSummaryComment = $true; EnableApprovalVote = $false }
        } | Should -Throw '*policy-changed*'
        # The prompt is read and deleted earlier in the function, before this live re-verification
        # step -- its removal is pre-existing behavior, unaffected by this change.
        Test-Path -LiteralPath $promptPath | Should -BeFalse
        # The lock must not have been left held after the rejected startup.
        $followUp = Enter-AgentCapabilityOverrideLock -RepositoryRoot $roots.RepoRoot -TimeoutMilliseconds 200
        $followUp.Acquired | Should -BeTrue
        Exit-AgentLock $followUp.Stream
    }
}
