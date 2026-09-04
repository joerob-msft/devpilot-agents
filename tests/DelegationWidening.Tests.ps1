BeforeAll {
    Import-Module "$PSScriptRoot\..\src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1" -Force
    $script:brokerPath = (Resolve-Path "$PSScriptRoot\..\tools\Invoke-DevPilotAgentDispatch.ps1").Path
    $script:harnessPath = (Resolve-Path "$PSScriptRoot\..\src\DevPilot.AgentHarness\DevPilot.AgentHarness.psm1").Path
    $script:reviewerPath = (Resolve-Path "$PSScriptRoot\..\src\Agents\reviewer\Start-ReviewerAgent.ps1").Path
    $script:handlerPath = (Resolve-Path "$PSScriptRoot\..\src\Agents\review-handler\Start-ReviewHandlerAgent.ps1").Path
    $script:realPolicyPath = (Resolve-Path "$PSScriptRoot\..\src\DevPilot.AgentHarness\Policy\delegation.policy.v1.json").Path

    # This repository's own working-tree ACL grants write access to a non-owner principal on this
    # host (a shared/mapped-drive checkout characteristic, not a product defect), which would fail
    # Assert-AgentTrustedFile's write-ACL check even without -Private. Every test below therefore
    # copies fixture content into a freshly hardened TestDrive toolkit root -- exactly the "temp
    # trusted module/toolkit copy" the production-path test guidance calls for -- rather than
    # exercising Get-AgentDelegationPolicy against the live checkout path directly. The production
    # CLI path/config never accepts an override for this location (Get-AgentDelegationPolicyPath is
    # unconditionally toolkit-root-relative); only these tests' own -ToolkitRoot argument varies.
    function New-TestToolkitRoot {
        param([Parameter(Mandatory)][string]$PolicyContent)
        $root = Join-Path $TestDrive ([Guid]::NewGuid().ToString('N'))
        $policyDir = Join-Path $root 'src\DevPilot.AgentHarness\Policy'
        New-Item -ItemType Directory -Path $policyDir -Force | Out-Null
        $policyPath = Join-Path $policyDir 'delegation.policy.v1.json'
        [IO.File]::WriteAllText($policyPath, $PolicyContent, [Text.UTF8Encoding]::new($false))
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $acl = [Security.AccessControl.DirectorySecurity]::new()
        $acl.SetOwner($identity.User)
        $acl.SetAccessRuleProtection($true, $false)
        $inheritance = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
                $identity.User, [Security.AccessControl.FileSystemRights]::FullControl, $inheritance, [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Allow))
        $systemSid = [Security.Principal.SecurityIdentifier]::new([Security.Principal.WellKnownSidType]::LocalSystemSid, $null)
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
                $systemSid, [Security.AccessControl.FileSystemRights]::FullControl, $inheritance, [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Allow))
        Set-Acl -LiteralPath $root -AclObject $acl
        return $root
    }

    function New-DefaultPolicyRecord {
        return [ordered]@{
            schemaVersion = 1
            roles         = [ordered]@{
                reviewer         = [ordered]@{ EnableApprovalVote = [ordered]@{ allowedRepositoryKeys = @() } }
                'review-handler' = [ordered]@{ EnableAutoComplete = [ordered]@{ allowedRepositoryKeys = @() } }
            }
        }
    }
}

Describe 'delegation policy trust and schema hardening (issue #105 PR4)' {
    It 'exports every new PR4 primitive at module scope and keeps it in the manifest' {
        $names = @(
            'Get-AgentDelegationPolicyPath', 'Get-AgentDelegationPolicy', 'Test-AgentDelegationAllows',
            'Get-AgentWideningGrantArtifactPath', 'New-AgentWideningGrantArtifact', 'Get-AgentWideningGrantArtifact',
            'Remove-AgentWideningGrantArtifact', 'New-AgentWideningChallenge', 'Test-AgentWideningChallengeShape',
            'Test-AgentAutoCompleteGrantWouldBeNoOp', 'Resolve-AgentWideningEffectiveDiff')
        foreach ($name in $names) { Get-Command $name -Module DevPilot.AgentHarness | Should -Not -BeNullOrEmpty }
        $manifestContent = Get-Content -LiteralPath (Resolve-Path "$PSScriptRoot\..\src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1").Path -Raw
        $moduleContent = Get-Content -LiteralPath $script:harnessPath -Raw
        foreach ($name in $names) {
            $manifestContent | Should -Match ([regex]::Escape("'$name'"))
            $moduleContent | Should -Match ([regex]::Escape("`"$name`""))
        }
    }

    It 'loads the real checked-in policy from a hardened toolkit copy as categorically empty/inert' {
        $root = New-TestToolkitRoot -PolicyContent (Get-Content -LiteralPath $script:realPolicyPath -Raw)
        $policy = Get-AgentDelegationPolicy -ToolkitRoot $root
        $policy.Delegations.reviewer.Capability | Should -BeExactly 'EnableApprovalVote'
        $policy.Delegations.reviewer.AllowedRepositoryKeys | Should -BeNullOrEmpty
        $policy.Delegations.'review-handler'.Capability | Should -BeExactly 'EnableAutoComplete'
        $policy.Delegations.'review-handler'.AllowedRepositoryKeys | Should -BeNullOrEmpty
        foreach ($role in @('reviewer', 'review-handler')) {
            $capability = $policy.Delegations[$role].Capability
            Test-AgentDelegationAllows -Policy $policy -Role $role -Capability $capability -RepositoryKey 'v1:github:any/repo' | Should -BeFalse
            Test-AgentDelegationAllows -Policy $policy -Role $role -Capability $capability -RepositoryKey 'v1:azuredevops:org/proj/repo' | Should -BeFalse
        }
        Test-AgentDelegationAllows -Policy $policy -Role reviewer -Capability 'EnableFindingComments' -RepositoryKey 'v1:github:any/repo' | Should -BeFalse
    }

    It 'content hash is sensitive to any byte change (tamper detection)' {
        $recordA = New-DefaultPolicyRecord
        $recordB = New-DefaultPolicyRecord
        $recordB.roles.reviewer.EnableApprovalVote.allowedRepositoryKeys = @('v1:github:contoso/widgets')
        # Same toolkit root/path both times -- isolates the assertion to CONTENT sensitivity
        # (PathHash must stay identical since the path did not change; ContentSha256 must not).
        $root = New-TestToolkitRoot -PolicyContent ($recordA | ConvertTo-Json -Depth 10)
        $policyA = Get-AgentDelegationPolicy -ToolkitRoot $root
        $policyPath = Get-AgentDelegationPolicyPath -ToolkitRoot $root
        [IO.File]::WriteAllText($policyPath, ($recordB | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
        $policyB = Get-AgentDelegationPolicy -ToolkitRoot $root
        $policyA.ContentSha256 | Should -Not -Be $policyB.ContentSha256
        $policyA.PathHash | Should -Be $policyB.PathHash
        $policyA.ContentSha256 | Should -Be $policyA.Fingerprint.Sha256
    }

    It 'has no wildcard/allow-any escape hatch -- grants only an explicit allowedRepositoryKeys entry (issue #105 PR4 requirement 8)' {
        $record = New-DefaultPolicyRecord
        $record.roles.reviewer.EnableApprovalVote.allowedRepositoryKeys = @('v1:github:contoso/widgets')
        $root = New-TestToolkitRoot -PolicyContent ($record | ConvertTo-Json -Depth 10)
        $policy = Get-AgentDelegationPolicy -ToolkitRoot $root
        Test-AgentDelegationAllows -Policy $policy -Role reviewer -Capability EnableApprovalVote -RepositoryKey 'v1:github:contoso/widgets' | Should -BeTrue
        Test-AgentDelegationAllows -Policy $policy -Role reviewer -Capability EnableApprovalVote -RepositoryKey 'v1:github:anything/at-all' | Should -BeFalse
        Test-AgentDelegationAllows -Policy $policy -Role 'review-handler' -Capability EnableAutoComplete -RepositoryKey 'v1:github:anything/at-all' | Should -BeFalse
        $scoped = New-DefaultPolicyRecord
        $scoped.roles.'review-handler'.EnableAutoComplete.allowedRepositoryKeys = @('v1:github:contoso/widgets')
        $root2 = New-TestToolkitRoot -PolicyContent ($scoped | ConvertTo-Json -Depth 10)
        $policy2 = Get-AgentDelegationPolicy -ToolkitRoot $root2
        Test-AgentDelegationAllows -Policy $policy2 -Role 'review-handler' -Capability EnableAutoComplete -RepositoryKey 'v1:github:contoso/widgets' | Should -BeTrue
        Test-AgentDelegationAllows -Policy $policy2 -Role 'review-handler' -Capability EnableAutoComplete -RepositoryKey 'v1:github:contoso/other' | Should -BeFalse
    }

    It 'fails closed on missing policy directory/file' {
        $missingRoot = Join-Path $TestDrive ([Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $missingRoot -Force | Out-Null
        { Get-AgentDelegationPolicy -ToolkitRoot $missingRoot } | Should -Throw '*delegation-policy-invalid*'
    }

    It 'rejects duplicate/case-collision keys, unknown fields, and every schema violation' {
        $cases = @(
            '{"schemaVersion":1,"schemaVersion":1,"roles":{}}'
            '{"schemaVersion":1,"Roles":{},"roles":{}}'
            '{"schemaVersion":2,"roles":{}}'
            '{"schemaVersion":1}'
            '{"schemaVersion":1,"roles":{},"extra":true}'
            '{"schemaVersion":1,"roles":{"reviewer":{"EnableApprovalVote":{"allowedRepositoryKeys":[],"allowAnyVerified":false}}}}'
            '{"schemaVersion":1,"roles":{"reviewer":{"EnableApprovalVote":{"allowedRepositoryKeys":[],"allowAnyVerified":false}},"REVIEWER":{"EnableApprovalVote":{"allowedRepositoryKeys":[],"allowAnyVerified":false}},"review-handler":{"EnableAutoComplete":{"allowedRepositoryKeys":[],"allowAnyVerified":false}}}}'
            '{"schemaVersion":1,"roles":{"reviewer":{"EnableAutoComplete":{"allowedRepositoryKeys":[],"allowAnyVerified":false}},"review-handler":{"EnableAutoComplete":{"allowedRepositoryKeys":[],"allowAnyVerified":false}}}}'
            '{"schemaVersion":1,"roles":{"reviewer":{"EnableApprovalVote":{"allowedRepositoryKeys":[],"allowAnyVerified":"false"}},"review-handler":{"EnableAutoComplete":{"allowedRepositoryKeys":[],"allowAnyVerified":false}}}}'
            '{"schemaVersion":1,"roles":{"reviewer":{"EnableApprovalVote":{"allowedRepositoryKeys":"none","allowAnyVerified":false}},"review-handler":{"EnableAutoComplete":{"allowedRepositoryKeys":[],"allowAnyVerified":false}}}}'
            '{"schemaVersion":1,"roles":{"reviewer":{"EnableApprovalVote":{"allowedRepositoryKeys":["not-a-repo-key"],"allowAnyVerified":false}},"review-handler":{"EnableAutoComplete":{"allowedRepositoryKeys":[],"allowAnyVerified":false}}}}'
            '{"schemaVersion":1,"roles":{"reviewer":{"EnableApprovalVote":{"allowedRepositoryKeys":["v1:github:x/y","v1:github:x/y"],"allowAnyVerified":false}},"review-handler":{"EnableAutoComplete":{"allowedRepositoryKeys":[],"allowAnyVerified":false}}}}'
            '{"schemaVersion":1,"roles":{"reviewer":{"EnableApprovalVote":{"allowedRepositoryKeys":[],"allowAnyVerified":false,"extra":1}},"review-handler":{"EnableAutoComplete":{"allowedRepositoryKeys":[],"allowAnyVerified":false}}}}'
        )
        foreach ($content in $cases) {
            $root = New-TestToolkitRoot -PolicyContent $content
            { Get-AgentDelegationPolicy -ToolkitRoot $root } | Should -Throw '*delegation-policy-invalid*' -Because $content
        }
    }
}

Describe 'grant-aware capability partition (issue #105 PR4 requirement 3)' {
    It 'moves exactly the one delegable capability from deny to active with a valid grant' {
        $roleDescriptor = @{ capabilities = @('EnableFindingComments', 'EnableThreadReplies'); mandatoryDenies = @('EnableApprovalVote') }
        $result = Resolve-AgentCapabilityPolicyPartition -RoleDescriptor $roleDescriptor -PersistedNarrowing @{} -GrantCapability 'EnableApprovalVote'
        $result.capabilities | Sort-Object | Should -BeExactly (@('EnableApprovalVote', 'EnableFindingComments', 'EnableThreadReplies') | Sort-Object)
        $result.mandatoryDenies | Should -BeExactly @()
    }

    It 'never relaxes a capability that is not currently an active mandatory deny' {
        $roleDescriptor = @{ capabilities = @('EnableFindingComments'); mandatoryDenies = @('EnableApprovalVote') }
        { Resolve-AgentCapabilityPolicyPartition -RoleDescriptor $roleDescriptor -PersistedNarrowing @{} -GrantCapability 'EnableCodeChanges' } |
            Should -Throw '*grant-invalid*'
        $alreadyActive = @{ capabilities = @('EnableApprovalVote'); mandatoryDenies = @() }
        { Resolve-AgentCapabilityPolicyPartition -RoleDescriptor $alreadyActive -PersistedNarrowing @{} -GrantCapability 'EnableApprovalVote' } |
            Should -Throw '*grant-invalid*'
    }

    It 'composes correctly with an unrelated persisted narrowing (exact partition, never subset)' {
        $roleDescriptor = @{ capabilities = @('EnableFindingComments', 'EnableThreadReplies'); mandatoryDenies = @('EnableApprovalVote') }
        $narrowing = @{ EnableThreadReplies = 'off' }
        $result = Resolve-AgentCapabilityPolicyPartition -RoleDescriptor $roleDescriptor -PersistedNarrowing $narrowing -GrantCapability 'EnableApprovalVote'
        $result.capabilities | Sort-Object | Should -BeExactly (@('EnableApprovalVote', 'EnableFindingComments') | Sort-Object)
        $result.mandatoryDenies | Sort-Object | Should -BeExactly (@('EnableThreadReplies') | Sort-Object)
    }

    It 'no grant capability leaves the partition byte-identical to the ungranted call' {
        $roleDescriptor = @{ capabilities = @('EnableFindingComments'); mandatoryDenies = @('EnableApprovalVote') }
        $withoutGrant = Resolve-AgentCapabilityPolicyPartition -RoleDescriptor $roleDescriptor -PersistedNarrowing @{}
        $withNullGrant = Resolve-AgentCapabilityPolicyPartition -RoleDescriptor $roleDescriptor -PersistedNarrowing @{} -GrantCapability $null
        (ConvertTo-AgentCanonicalJson $withoutGrant) | Should -BeExactly (ConvertTo-AgentCanonicalJson $withNullGrant)
    }

    It 'renders the reviewer vote pairing and flags an inactive paired capability' {
        $current = @{ capabilities = @('EnableThreadReplies'); mandatoryDenies = @('EnableApprovalVote') }
        $widened = @{ capabilities = @('EnableApprovalVote', 'EnableThreadReplies'); mandatoryDenies = @() }
        $diff = Resolve-AgentWideningEffectiveDiff -Current $current -Widened $widened -Role reviewer -GrantCapability 'EnableApprovalVote'
        $diff.addedCapabilities | Should -BeExactly @('EnableApprovalVote')
        $diff.pairedCapability | Should -BeExactly 'EnableFindingComments'
        $diff.pairedCapabilityActive | Should -BeFalse
        $widenedWithComments = @{ capabilities = @('EnableApprovalVote', 'EnableFindingComments', 'EnableThreadReplies'); mandatoryDenies = @() }
        $diff2 = Resolve-AgentWideningEffectiveDiff -Current $current -Widened $widenedWithComments -Role reviewer -GrantCapability 'EnableApprovalVote'
        $diff2.pairedCapabilityActive | Should -BeTrue
    }
}

Describe 'sealed grant-selection artifact (issue #105 PR4 requirement 8)' {
    BeforeEach {
        $script:runtimeRoot = Join-Path $TestDrive ([Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:runtimeRoot -Force | Out-Null
        $script:validArgs = @{
            RuntimeRoot = $script:runtimeRoot; DraftId = [Guid]::NewGuid().ToString('D'); DispatchId = [Guid]::NewGuid().ToString('D')
            Capability = 'EnableApprovalVote'; Role = 'reviewer'; RepositoryKey = 'v1:github:contoso/widgets'
            WorktreeId = ('a' * 64); PullRequestId = 7; SourceCommit = ('b' * 40)
            PolicyPathHash = ('c' * 64); PolicyContentSha256 = ('d' * 64)
            GrantNonce = (New-AgentNonce); ExpiresAtUtc = (ConvertTo-AgentCanonicalEpochSeconds ([DateTime]::UtcNow.AddMinutes(10)))
        }
    }

    It 'round-trips every field and is owner-private' {
        $path = New-AgentWideningGrantArtifact @script:validArgs
        Test-Path -LiteralPath $path | Should -BeTrue
        { Assert-AgentTrustedFile -Path $path -AllowedRoot $script:runtimeRoot -ExpectedPath $path -Private } | Should -Not -Throw
        $read = Get-AgentWideningGrantArtifact -RuntimeRoot $script:runtimeRoot
        $read.DraftId | Should -Be $script:validArgs.DraftId
        $read.DispatchId | Should -Be $script:validArgs.DispatchId
        $read.Capability | Should -BeExactly 'EnableApprovalVote'
        $read.RepositoryKey | Should -Be $script:validArgs.RepositoryKey
        $read.WorktreeId | Should -Be $script:validArgs.WorktreeId
        $read.PullRequestId | Should -Be 7
        $read.SourceCommit | Should -Be $script:validArgs.SourceCommit
        $read.GrantNonce | Should -Be $script:validArgs.GrantNonce
        $read.ExpiresAtUtc | Should -Be $script:validArgs.ExpiresAtUtc
    }

    It 'returns $null when absent, never fabricating a grant' {
        Get-AgentWideningGrantArtifact -RuntimeRoot $script:runtimeRoot | Should -BeNullOrEmpty
    }

    It 'fails closed on a tampered field rather than silently reinterpreting it' {
        $path = New-AgentWideningGrantArtifact @script:validArgs
        $record = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
        $record.capability = 'EnableAutoComplete'
        [IO.File]::WriteAllText($path, (ConvertTo-AgentCanonicalJson $record), [Text.UTF8Encoding]::new($false))
        { Get-AgentWideningGrantArtifact -RuntimeRoot $script:runtimeRoot } | Should -Not -Throw
        $record2 = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
        $record2.worktreeId = 'not-64-hex'
        [IO.File]::WriteAllText($path, (ConvertTo-AgentCanonicalJson $record2), [Text.UTF8Encoding]::new($false))
        { Get-AgentWideningGrantArtifact -RuntimeRoot $script:runtimeRoot } | Should -Throw '*grant-invalidated*'
    }

    It 'rejects an unknown extra field and a missing required field' {
        $path = New-AgentWideningGrantArtifact @script:validArgs
        $record = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
        $record['unexpectedField'] = 'x'
        [IO.File]::WriteAllText($path, (ConvertTo-AgentCanonicalJson $record), [Text.UTF8Encoding]::new($false))
        { Get-AgentWideningGrantArtifact -RuntimeRoot $script:runtimeRoot } | Should -Throw '*grant-invalidated*'
        $record2 = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
        $record2.Remove('grantNonce')
        [IO.File]::WriteAllText($path, (ConvertTo-AgentCanonicalJson $record2), [Text.UTF8Encoding]::new($false))
        { Get-AgentWideningGrantArtifact -RuntimeRoot $script:runtimeRoot } | Should -Throw '*grant-invalidated*'
    }

    It 'Remove- deletes the artifact and a second call is a benign no-op' {
        [void](New-AgentWideningGrantArtifact @script:validArgs)
        Remove-AgentWideningGrantArtifact -RuntimeRoot $script:runtimeRoot
        Test-Path -LiteralPath (Get-AgentWideningGrantArtifactPath -RuntimeRoot $script:runtimeRoot) | Should -BeFalse
        { Remove-AgentWideningGrantArtifact -RuntimeRoot $script:runtimeRoot } | Should -Not -Throw
    }

    It 'rejects malformed identifiers on write (fixed shapes, never accepted loosely)' {
        { New-AgentWideningGrantArtifact @script:validArgs -PullRequestId -1 } | Should -Throw
        { New-AgentWideningGrantArtifact @script:validArgs -SourceCommit 'tooshort' } | Should -Throw
        { New-AgentWideningGrantArtifact @script:validArgs -Role 'admin' } | Should -Throw
    }
}

Describe 'widening challenge primitives (issue #105 PR4 requirement 4)' {
    It 'produces correctly-shaped, unique, single-use-ready challenges' {
        $challenges = 1..64 | ForEach-Object { New-AgentWideningChallenge }
        foreach ($c in $challenges) { Test-AgentWideningChallengeShape -Challenge $c | Should -BeTrue }
        (@($challenges | Sort-Object -Unique)).Count | Should -Be 64
    }

    It 'rejects wrong length, case, and non-hex challenge shapes' {
        Test-AgentWideningChallengeShape -Challenge ('a' * 47) | Should -BeFalse
        Test-AgentWideningChallengeShape -Challenge ('A' * 48) | Should -BeFalse
        Test-AgentWideningChallengeShape -Challenge ('g' * 48) | Should -BeFalse
        Test-AgentWideningChallengeShape -Challenge '' | Should -BeFalse
    }
}

Describe 'review-handler auto-complete grant no-op guard (issue #105 PR4 requirement 6)' {
    It 'flags exactly when the PR already has durable handled-state, nothing more' {
        Test-AgentAutoCompleteGrantWouldBeNoOp -HandledState @{} -PullRequestId 5 | Should -BeFalse
        Test-AgentAutoCompleteGrantWouldBeNoOp -HandledState @{ '5' = @{ sourceCommit = ('a' * 40) } } -PullRequestId 5 | Should -BeTrue
        Test-AgentAutoCompleteGrantWouldBeNoOp -HandledState @{ '6' = @{ sourceCommit = ('a' * 40) } } -PullRequestId 5 | Should -BeFalse
    }
}

Describe 'broker widening protocol wiring (source-regex, matches existing DispatchProtocol.Tests.ps1 style)' {
    BeforeAll { $script:brokerSource = Get-Content -LiteralPath $script:brokerPath -Raw }

    It 'registers all four widening operations on the request switch' {
        foreach ($op in @('describe-widening', 'confirm-widening-preview', 'confirm-widening-mint', 'cancel-widening')) {
            $script:brokerSource | Should -Match ([regex]::Escape("'$op'"))
        }
        $script:brokerSource | Should -Match 'Invoke-DescribeWidening'
        $script:brokerSource | Should -Match 'Invoke-ConfirmWideningPreview'
        $script:brokerSource | Should -Match 'Invoke-ConfirmWideningMint'
        $script:brokerSource | Should -Match 'Invoke-CancelWidening'
    }

    It 'delegation eligibility is checked-in-policy driven, never a broker-local allowlist' {
        $script:brokerSource | Should -Match 'Get-AgentDelegationPolicyOr(Null|Throw) -ToolkitRoot \$toolkitRoot'
        $script:brokerSource | Should -Match 'Test-AgentDelegationAllows'
        $script:brokerSource | Should -Not -Match "allowAnyVerified\s*=\s*\`$true"
        # issue #105 PR4 requirement 8: no wildcard/allow-any escape hatch anywhere in the schema.
        $script:brokerSource | Should -Not -Match 'allowAnyVerified'
    }

    It 'bounds the per-draft consumed-challenge ring at 8 and the global requestId set' {
        $script:brokerSource | Should -Match '\$Widening\.ConsumedChallenges\.Count -gt 8'
        $script:brokerSource | Should -Match 'MaxTrackedRequestIds'
        $script:brokerSource | Should -Match 'Register-BrokerRequestId'
        $script:brokerSource | Should -Not -Match '-not \$requestIds\.Add\(\$requestId\)'
    }

    It 'omits -ForceAnalysis only for a reviewer vote-grant dispatch, before the args array is built' {
        $includeIdx = $script:brokerSource.IndexOf('$includeForceAnalysis =')
        $argsIdx = $script:brokerSource.IndexOf("'-PullRequestId', [string]`$draft.PullRequestId, '-Once')")
        $includeIdx | Should -BeGreaterThan -1
        $argsIdx | Should -BeGreaterThan $includeIdx
        $script:brokerSource | Should -Match "-not \(\`$draft\.Role -eq 'reviewer' -and \`$grantCapability -ceq 'EnableApprovalVote'\)"
        $script:brokerSource | Should -Not -Match "'-Once', '-ForceAnalysis'"
    }

    It 'revalidates an expired/invalidated grant and the handler no-op guard before allocating dispatchId' {
        $grantCheckIdx = $script:brokerSource.IndexOf('grant-invalidated')
        $dispatchIdIdx = $script:brokerSource.IndexOf('$dispatchId = [Guid]::NewGuid()')
        $grantCheckIdx | Should -BeGreaterThan -1
        $dispatchIdIdx | Should -BeGreaterThan $grantCheckIdx
        $script:brokerSource | Should -Match 'grant-noop'
    }

    It 'seals the grant artifact before launch and removes it only after proceed is sent, before accepted' {
        $sealIdx = $script:brokerSource.IndexOf('New-AgentWideningGrantArtifact -RuntimeRoot')
        $manifestWriteIdx = $script:brokerSource.IndexOf('[IO.File]::WriteAllText($manifestPath')
        $proceedIdx = $script:brokerSource.IndexOf("operation = 'proceed'")
        $removeIdx = $script:brokerSource.IndexOf('Remove-AgentWideningGrantArtifact -RuntimeRoot', $proceedIdx)
        $acceptedIdx = $script:brokerSource.IndexOf("operation = 'accepted'")
        $sealIdx | Should -BeGreaterThan -1
        $manifestWriteIdx | Should -BeGreaterThan $sealIdx
        $removeIdx | Should -BeGreaterThan $proceedIdx
        $acceptedIdx | Should -BeGreaterThan $removeIdx
    }

    It 'never adds a RunspacePool/BeginInvoke-based async worker for the widening protocol' {
        $script:brokerSource | Should -Not -Match 'RunspacePool'
        $script:brokerSource | Should -Not -Match 'BeginInvoke'
    }
}

Describe 'headless/direct dispatch guards (issue #105 PR4 requirement 7)' {
    It 'reviewer and review-handler refuse the delegable switch without a sealed manifest, before any network/provider call' {
        $reviewerSource = Get-Content -LiteralPath $script:reviewerPath -Raw
        $reviewerSource | Should -Match "if \(\`$EnableApprovalVote -and -not \`$ManualDispatchManifest\)"
        $guardIdx = $reviewerSource.IndexOf('-EnableApprovalVote requires a sealed manual dispatch grant')
        $tryIdx = $reviewerSource.IndexOf('# One top-level try/catch')
        $guardIdx | Should -BeGreaterThan -1
        $tryIdx | Should -BeGreaterThan $guardIdx
        $handlerSource = Get-Content -LiteralPath $script:handlerPath -Raw
        $handlerSource | Should -Match "if \(\`$EnableAutoComplete -and -not \`$ManualDispatchManifest\)"
        $handlerGuardIdx = $handlerSource.IndexOf('-EnableAutoComplete requires a sealed manual dispatch grant')
        $handlerTryIdx = $handlerSource.IndexOf('# One top-level try/catch')
        $handlerGuardIdx | Should -BeGreaterThan -1
        $handlerTryIdx | Should -BeGreaterThan $handlerGuardIdx
    }

    It 'the reviewer process throws before any provider/network call when EnableApprovalVote is requested directly' {
        $psi = [Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = (Get-Process -Id $PID).Path
        if ($psi.FileName -notmatch 'pwsh') { $psi.FileName = 'pwsh' }
        $psi.ArgumentList.Add('-NoLogo'); $psi.ArgumentList.Add('-NoProfile'); $psi.ArgumentList.Add('-NonInteractive')
        $psi.ArgumentList.Add('-File'); $psi.ArgumentList.Add($script:reviewerPath)
        $psi.ArgumentList.Add('-Organization'); $psi.ArgumentList.Add('contoso')
        $psi.ArgumentList.Add('-RepositoryName'); $psi.ArgumentList.Add('widgets')
        $psi.ArgumentList.Add('-EnableApprovalVote')
        $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.UseShellExecute = $false
        $proc = [Diagnostics.Process]::Start($psi)
        $stderr = $proc.StandardError.ReadToEnd()
        [void]$proc.StandardOutput.ReadToEnd()
        $proc.WaitForExit(15000) | Should -BeTrue
        $proc.ExitCode | Should -Not -Be 0
        $stderr | Should -Match 'requires a sealed manual dispatch grant'
    }
}
