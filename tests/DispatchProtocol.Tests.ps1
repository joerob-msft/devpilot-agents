BeforeAll {
    Import-Module "$PSScriptRoot\..\src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1" -Force
    $script:brokerPath = (Resolve-Path "$PSScriptRoot\..\tools\Invoke-DevPilotAgentDispatch.ps1").Path
    $script:watchPath = (Resolve-Path "$PSScriptRoot\..\tools\Watch-DevPilotAgents.ps1").Path
    $script:reviewerPath = (Resolve-Path "$PSScriptRoot\..\src\Agents\reviewer\Start-ReviewerAgent.ps1").Path
    $script:handlerPath = (Resolve-Path "$PSScriptRoot\..\src\Agents\review-handler\Start-ReviewHandlerAgent.ps1").Path
    $script:guardianPath = (Resolve-Path "$PSScriptRoot\..\tools\Invoke-DevPilotPromptGuardian.ps1").Path
    $script:reviewerAclToRestore = $null
    if ($IsWindows) {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $currentSid = $identity.User
        $systemSid = [Security.Principal.SecurityIdentifier]::new(
            [Security.Principal.WellKnownSidType]::LocalSystemSid, $null)
        $administratorsSid = [Security.Principal.SecurityIdentifier]::new(
            [Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid, $null)
        $writeRights = [Security.AccessControl.FileSystemRights]::Write -bor
            [Security.AccessControl.FileSystemRights]::Modify -bor
            [Security.AccessControl.FileSystemRights]::FullControl -bor
            [Security.AccessControl.FileSystemRights]::Delete -bor
            [Security.AccessControl.FileSystemRights]::ChangePermissions -bor
            [Security.AccessControl.FileSystemRights]::TakeOwnership
        $existingAcl = Get-Acl -LiteralPath $script:reviewerPath
        $hasUnsafeWriter = @($existingAcl.GetAccessRules(
                $true, $true, [Security.Principal.SecurityIdentifier]) | Where-Object {
                $_.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and
                $_.IdentityReference -ne $currentSid -and
                $_.IdentityReference -ne $systemSid -and
                $_.IdentityReference -ne $administratorsSid -and
                (($_.FileSystemRights -band $writeRights) -ne 0)
            }).Count -gt 0
        if ($hasUnsafeWriter) {
            $script:reviewerAclToRestore = $existingAcl
            $trustedAcl = [Security.AccessControl.FileSecurity]::new()
            $trustedAcl.SetOwner($currentSid)
            $trustedAcl.SetAccessRuleProtection($true, $false)
            foreach ($trustedSid in @($currentSid, $systemSid)) {
                $trustedAcl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
                        $trustedSid, [Security.AccessControl.FileSystemRights]::FullControl,
                        [Security.AccessControl.AccessControlType]::Allow))
            }
            Set-Acl -LiteralPath $script:reviewerPath -AclObject $trustedAcl
        }
    }
}

AfterAll {
    if ($script:reviewerAclToRestore) {
        Set-Acl -LiteralPath $script:reviewerPath -AclObject $script:reviewerAclToRestore
    }
}

Describe 'dispatch protocol primitives' {
    It 'emits deterministic canonical JSON and separate digests' {
        ConvertTo-AgentCanonicalJson ([ordered]@{ z = 2; a = @($true, $null, 'x') }) |
            Should -BeExactly '{"a":[true,null,"x"],"z":2}'
        ConvertTo-AgentCanonicalJson ([ordered]@{ capabilities = [object[]]@() }) |
            Should -BeExactly '{"capabilities":[]}'
        Get-AgentCanonicalDigest @{ role = 'reviewer'; source = 'a' } |
            Should -Not -Be (Get-AgentCanonicalDigest @{ role = 'reviewer'; source = 'b' })
    }

    It 'normalizes multiline prompts and counts Unicode scalar values' {
        $result = Test-AgentOperatorPrompt ("line1`r`nline2`n" + ([char]::ConvertFromUtf32(0x1F680)))
        $result.Text | Should -BeExactly "line1`nline2`n🚀"
        $result.ScalarCount | Should -Be 13
        $result.Preview | Should -Be '[operator context redacted]'
    }

    It 'accepts 512 non-BMP scalars and rejects 513 or controls' {
        $rune = [char]::ConvertFromUtf32(0x1F680)
        (Test-AgentOperatorPrompt ($rune * 512)).ScalarCount | Should -Be 512
        { Test-AgentOperatorPrompt ($rune * 513) } | Should -Throw '*512 Unicode scalar*'
        { Test-AgentOperatorPrompt "bad$([char]0x1b)" } | Should -Throw '*control character*'
    }

    It 'keeps one protocol writer and requires versioned draft binding' {
        $source = Get-Content -LiteralPath $brokerPath -Raw
        ([regex]::Matches($source, 'function Write-DispatchProtocolMessage')).Count | Should -Be 1
        $source | Should -Match '\[AllowEmptyCollection\(\)\]\[string\[\]\]\$AbsoluteDenies'
        $source | Should -Match 'dispatchDraftId'
        $source | Should -Match 'DraftLifetimeSeconds'
        $source | Should -Match 'capabilityPolicyDigest'
        $source | Should -Match 'prStateFingerprint'
        $source | Should -Match 'source-changed'
    }

    It 'orders child ready, broker proceed, and public accepted' {
        $source = Get-Content -LiteralPath $brokerPath -Raw
        $ready = $source.IndexOf("$ready =")
        $proceed = $source.IndexOf("operation = 'proceed'", $ready)
        $accepted = $source.IndexOf("operation = 'accepted'", $proceed)
        $ready | Should -BeGreaterThan -1
        $proceed | Should -BeGreaterThan $ready
        $accepted | Should -BeGreaterThan $proceed
    }

    It 'authenticates typed startup rejections before mapping contention' {
        $source = Get-Content -LiteralPath $brokerPath -Raw
        $rejection = $source.IndexOf("operation -ceq 'rejected'")
        $identity = $source.IndexOf('Child rejection identity mismatch', $rejection)
        $mapping = $source.IndexOf('$startupCode = [string](Get-OptionalMember $ready ''code'')', $identity)
        $rejection | Should -BeGreaterThan -1
        $identity | Should -BeGreaterThan $rejection
        $mapping | Should -BeGreaterThan $identity
    }

    It 'contains no lease bypass switch and makes the child acquire authority' {
        (Get-Content -LiteralPath $brokerPath -Raw) | Should -Not -Match 'SkipLease|LeaseAlreadyHeld'
        $reviewer = Get-Content -LiteralPath $reviewerPath -Raw
        $reviewer | Should -Match 'Enter-AgentManualDispatchStartup'
        $reviewer | Should -Not -Match '\[switch\]\$SkipLease'
    }

    It 'exports manual startup and context functions at module scope' {
        Get-Command Enter-AgentManualDispatchStartup -Module DevPilot.AgentHarness |
            Should -Not -BeNullOrEmpty
        Get-Command Get-AgentManualOperatorContext -Module DevPilot.AgentHarness |
            Should -Not -BeNullOrEmpty
        Get-Command Exit-AgentManualDispatchAuthority -Module DevPilot.AgentHarness |
            Should -Not -BeNullOrEmpty
        Get-Command Test-AgentPathWithin -Module DevPilot.AgentHarness |
            Should -Not -BeNullOrEmpty
    }

    It 'performs separator-aware path containment' {
        $root = Join-Path $TestDrive 'containment-root'
        Test-AgentPathWithin -Path (Join-Path $root 'child\file.json') -Root $root |
            Should -BeTrue
        Test-AgentPathWithin -Path $root -Root $root | Should -BeTrue
        Test-AgentPathWithin -Path "$root-sibling\file.json" -Root $root |
            Should -BeFalse
    }

    It 'only reads manual operator context in manual mode for both roles' {
        foreach ($path in @($reviewerPath, $handlerPath)) {
            $source = Get-Content -LiteralPath $path -Raw
            $source | Should -Match 'if \(\$ManualDispatchManifest\)\s*\{\s*Get-AgentManualOperatorContext'
            $source | Should -Match 'Exit-AgentManualDispatchAuthority'
        }
    }

    It 'keeps manual policy independent and makes Reviewer vote impossible' {
        $source = Get-Content -LiteralPath $watchPath -Raw
        $source | Should -Match 'EnableManualReviewer'
        $source | Should -Match 'mandatoryDenies = @\(\$reviewerCapabilityDescriptor\.delegableDefaultOff\)'
        $source | Should -Not -Match "manualRoles\.reviewer.+EnableApprovalVote"
        $source | Should -Not -Match "'EnableApprovalVote'"
        (Get-AgentHarnessCapabilityDescriptor -Role reviewer).delegableDefaultOff | Should -BeExactly 'EnableApprovalVote'
    }

    It 'exports a single-source, grant-free capability descriptor with exact golden values' {
        Get-Command Get-AgentHarnessCapabilityDescriptor -Module DevPilot.AgentHarness |
            Should -Not -BeNullOrEmpty
        $reviewer = Get-AgentHarnessCapabilityDescriptor -Role reviewer
        $reviewer.operationalTiers.base | Should -BeExactly @('EnableFindingComments', 'EnableThreadReplies', 'EnableSummaryComment')
        $reviewer.operationalTiers.Contains('codeUpdate') | Should -BeFalse
        $reviewer.delegableDefaultOff | Should -BeExactly 'EnableApprovalVote'
        (@($reviewer.allowedManualCapabilities | Sort-Object)) |
            Should -BeExactly (@('EnableFindingComments', 'EnableSummaryComment', 'EnableThreadReplies') | Sort-Object)
        $reviewer.absoluteDenies | Should -BeExactly @()

        $handler = Get-AgentHarnessCapabilityDescriptor -Role review-handler
        $handler.operationalTiers.base | Should -BeExactly @('EnableThreadReplies', 'EnableBuddyRequeue')
        $handler.operationalTiers.codeUpdate | Should -BeExactly @('EnableCodeChanges', 'EnablePush', 'LocalValidation', 'ResumeCodingSession')
        $handler.delegableDefaultOff | Should -BeExactly 'EnableAutoComplete'
        (@($handler.allowedManualCapabilities | Sort-Object)) |
            Should -BeExactly (@('EnableThreadReplies', 'EnableBuddyRequeue', 'EnableCodeChanges', 'EnablePush', 'LocalValidation', 'ResumeCodingSession') | Sort-Object)
        $handler.absoluteDenies | Should -BeExactly @()

        # Disjointness: the default-off delegable capability is never part of either role's
        # always-on manual ceiling, and absoluteDenies (empty in PR1) never overlaps it either.
        $reviewer.allowedManualCapabilities | Should -Not -Contain $reviewer.delegableDefaultOff
        $handler.allowedManualCapabilities | Should -Not -Contain $handler.delegableDefaultOff
        @($reviewer.absoluteDenies | Where-Object { $reviewer.allowedManualCapabilities -contains $_ }) | Should -BeNullOrEmpty
        @($handler.absoluteDenies | Where-Object { $handler.allowedManualCapabilities -contains $_ }) | Should -BeNullOrEmpty
    }

    It 'returns a fresh, independently-mutable projection on every call' {
        $first = Get-AgentHarnessCapabilityDescriptor -Role review-handler
        $first.operationalTiers.base += 'Injected'
        $first.allowedManualCapabilities += 'Injected'
        $second = Get-AgentHarnessCapabilityDescriptor -Role review-handler
        $second.operationalTiers.base | Should -Not -Contain 'Injected'
        $second.allowedManualCapabilities | Should -Not -Contain 'Injected'
        $second.operationalTiers.base | Should -BeExactly @('EnableThreadReplies', 'EnableBuddyRequeue')
    }

    It 'keeps capability literals declared in exactly one place (the harness descriptor)' {
        $literals = @('EnableFindingComments', 'EnableThreadReplies', 'EnableSummaryComment', 'EnableApprovalVote',
            'EnableBuddyRequeue', 'EnableCodeChanges', 'EnablePush', 'LocalValidation', 'ResumeCodingSession', 'EnableAutoComplete')
        $watchSource = Get-Content -LiteralPath $watchPath -Raw
        foreach ($literal in $literals) {
            $watchSource | Should -Not -Match "'$literal'"
        }
        $brokerSource = Get-Content -LiteralPath $brokerPath -Raw
        $roleDescriptorBody = [regex]::Match($brokerSource, '(?s)function Get-RoleDescriptor \{.*?\n\}').Value
        $roleDescriptorBody | Should -Not -BeNullOrEmpty
        foreach ($literal in $literals) {
            $roleDescriptorBody | Should -Not -Match "'$literal'"
        }
        $harnessSource = Get-Content -LiteralPath "$PSScriptRoot\..\src\DevPilot.AgentHarness\DevPilot.AgentHarness.psm1" -Raw
        $startupBody = [regex]::Match($harnessSource, '(?s)function Enter-AgentManualDispatchStartup \{.*?\r?\n\}').Value
        $startupBody | Should -Not -BeNullOrEmpty
        foreach ($literal in $literals) {
            $startupBody | Should -Not -Match "'$literal'"
        }
        $descriptorBody = [regex]::Match($harnessSource, '(?s)function Get-AgentHarnessCapabilityDescriptor \{.*?\r?\n\}').Value
        $descriptorBody | Should -Not -BeNullOrEmpty
        foreach ($literal in $literals) {
            $descriptorBody | Should -Match "'$literal'"
        }
    }

    It 'launches only immutable digest-bound capabilities and rejects deny overlap' {
        $source = Get-Content -LiteralPath $brokerPath -Raw
        $source | Should -Match 'foreach \(\$capability in @\(\$draft\.Policy\.capabilities\)\)'
        $source | Should -Not -Match 'foreach \(\$capability in @\(\$draft\.RoleDescriptor\.capabilities\)\)'
        $source | Should -Match '\$mandatoryDenies -ccontains \$_'

        $manifest = Join-Path $TestDrive 'overlap-manifest.json'
        @{
            schemaVersion = 1
            role = 'reviewer'
            dispatchId = [Guid]::NewGuid().ToString('D')
            policy = @{
                role = 'reviewer'
                capabilities = @('EnableApprovalVote')
                mandatoryDenies = @('EnableApprovalVote')
                ceilingCapabilities = @('EnableApprovalVote')
                ceilingMandatoryDenies = @('EnableApprovalVote')
            }
            capabilityPolicyDigest = 'invalid'
        } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $manifest -Encoding utf8NoBOM
        {
            Enter-AgentManualDispatchStartup -ManifestPath $manifest -RepositoryIdentity @{
                key = 'v1:github:1'; verified = $true
            } -RepositoryRoot $TestDrive -DurableContext @{} -LeaseRoot $TestDrive -Role reviewer `
                -EventLogPath (Join-Path $TestDrive 'event.jsonl') `
                -BoundCapabilities @{ EnableApprovalVote = $false }
        } | Should -Throw '*policy is malformed or inconsistent*'
    }

    It 'rejects bound capability switches that differ from the digest-bound manifest' {
        $policy = [ordered]@{
            schemaVersion = 1
            repositoryIdentity = @{ key = 'v1:github:1'; verified = $true }
            role = 'reviewer'
            capabilities = @('EnableFindingComments')
            mandatoryDenies = @('EnableApprovalVote')
            ceilingCapabilities = @('EnableFindingComments')
            ceilingMandatoryDenies = @('EnableApprovalVote')
            configSnapshotSha256 = ('a' * 64)
        }
        $manifest = Join-Path $TestDrive 'capability-mismatch-manifest.json'
        @{
            schemaVersion = 1
            role = 'reviewer'
            dispatchId = [Guid]::NewGuid().ToString('D')
            policy = $policy
            capabilityPolicyDigest = Get-AgentCanonicalDigest $policy
        } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $manifest -Encoding utf8NoBOM
        {
            Enter-AgentManualDispatchStartup -ManifestPath $manifest -RepositoryIdentity @{
                key = 'v1:github:1'; verified = $true
            } -RepositoryRoot $TestDrive -DurableContext @{} -LeaseRoot $TestDrive -Role reviewer `
                -EventLogPath (Join-Path $TestDrive 'event.jsonl') `
                -BoundCapabilities @{
                    EnableFindingComments = $false
                    EnableApprovalVote = $false
                }
        } | Should -Throw '*policy is malformed or inconsistent*'
        {
            Enter-AgentManualDispatchStartup -ManifestPath $manifest -RepositoryIdentity @{
                key = 'v1:github:1'; verified = $true
            } -RepositoryRoot $TestDrive -DurableContext @{} -LeaseRoot $TestDrive -Role reviewer `
                -EventLogPath (Join-Path $TestDrive 'event.jsonl') `
                -BoundCapabilities @{
                    EnableFindingComments = $true
                    EnableApprovalVote = $true
                }
        } | Should -Throw '*policy is malformed or inconsistent*'
    }

    It 'uses typed launch rather than encoded commands' {
        $source = Get-Content -LiteralPath $watchPath -Raw
        $source | Should -Match 'New-AgentRedirectedProcess'
        $source | Should -Not -Match 'EncodedCommand|Start-Process'
    }

    It 'uses the platform-specific locked Bun executable' {
        $source = Get-Content -LiteralPath (Resolve-Path "$PSScriptRoot\..\tools\Start-DevPilotDashboard.ps1") -Raw
        $source | Should -Match '\$IsWindows'
        $source | Should -Match "'bun\.exe'"
        $source | Should -Match "'bun'"
        $source | Should -Not -Match "node_modules\\\\|dist\\\\src|@opentui\\\\|tools\\\\Invoke-DevPilotAgentDispatch"
    }

    It 'reaps drafts and reports pre-ready startup failures before acceptance' {
        $source = Get-Content -LiteralPath $brokerPath -Raw
        $source | Should -Match 'function Remove-ExpiredDrafts'
        $source | Should -Match 'Remove-ExpiredDrafts\s*\r?\n\s*\$role'
        $source | Should -Match "operation -ceq 'rejected'"
        $source | Should -Match 'Child exited before readiness'
        $source.IndexOf('Complete-AgentRedirectedProcess $child') |
            Should -BeLessThan $source.IndexOf('Child exited before readiness')
    }

    It 'describes and authoritatively blocks pending reviewer delivery' {
        $source = Get-Content -LiteralPath $brokerPath -Raw
        $source | Should -Match "constraints \+= 'delivery-pending'"
        $module = Get-Content -LiteralPath (Resolve-Path "$PSScriptRoot\..\src\DevPilot.AgentHarness\DevPilot.AgentHarness.psm1") -Raw
        $module | Should -Match "throw '\[delivery-pending\]"
        $module | Should -Match "operation = 'rejected'"
    }

    It 'shows provider-bound authoritative v2 state instead of presenting legacy state as current' {
        foreach ($relativePath in @(
                '..\src\Agents\reviewer\Start-ReviewerAgent.ps1',
                '..\src\Agents\review-handler\Start-ReviewHandlerAgent.ps1')) {
            $source = Get-Content -LiteralPath (Resolve-Path (Join-Path $PSScriptRoot $relativePath)) -Raw
            $source | Should -Match 'Resolve-AgentProviderRepositoryIdentity'
            $source | Should -Match 'Get-AgentDurableStateContext'
            $source | Should -Match 'Get-AgentDurableRecordsSnapshot'
            $source | Should -Match 'Authoritative durable state v2'
            $source | Should -Match 'Durable state v2 is uninitialized'
            $source | Should -Match 'Migration or explicit initialization is required'
            $source | Should -Match 'Legacy operational failure attempts'
        }
    }

    It 'captures bounded guardian stderr before launch-failure cleanup' {
        $source = Get-Content -LiteralPath $brokerPath -Raw
        $source | Should -Match '\$guardianCompletion = Complete-AgentRedirectedProcess \$guardian'
        $source | Should -Match 'did not become ready: \$\(\$guardianCompletion\.SafeErrorTail\)'
        $source | Should -Match 'did not register the protected identity: \$\(\$guardianCompletion\.SafeErrorTail\)'
    }

    It 'stores manual reviewer plans under the durable role root until resolved' {
        $source = Get-Content -LiteralPath $reviewerPath -Raw
        $source | Should -Match 'Join-Path \$script:ReviewerDurableContext\.RoleRoot ''pending-artifacts'''
        $source | Should -Match '\$ManualDispatchManifest -and \$pendingArtifactDir'
        $source | Should -Match 'Test-AgentPathWithin -Path \$artifactPath -Root \$pendingArtifactDir'
    }

    It 'requests cooperative cancellation before bounded forced containment' {
        $source = Get-Content -LiteralPath $brokerPath -Raw
        $write = $source.IndexOf('[IO.File]::WriteAllText($cancelPath')
        $wait = $source.IndexOf('$entry.Child.Process.WaitForExit(5000)', $write)
        $force = $source.IndexOf('Stop-AgentProcessContainment $entry.Containment', $wait)
        $write | Should -BeGreaterThan -1
        $wait | Should -BeGreaterThan $write
        $force | Should -BeGreaterThan $wait
        $source | Should -Match "'termination-failed'"
        $source.IndexOf('$terminated = Stop-AgentProcessContainment') |
            Should -BeLessThan $source.IndexOf("if (`$outcome.Result -eq 'termination-failed')")
    }

    It 'validates guardian identity for mutating signals and observes exited groups without signaling' {
        $source = Get-Content -LiteralPath $guardianPath -Raw
        ([regex]::Matches($source, '\[DevPilot\.PromptGuardian\.Native\]::kill')).Count | Should -Be 1
        $signalFunction = $source.Substring(
            $source.IndexOf('function Invoke-GuardianGroupSignal'),
            $source.IndexOf('function Test-GuardianGroupAlive') - $source.IndexOf('function Invoke-GuardianGroupSignal'))
        $signalFunction | Should -Match 'Get-Process -Id \$ProcessGroupId'
        $signalFunction | Should -Match '\$ProcessGroupId -le 1'
        $signalFunction | Should -Match '\$leader\.Id -ne \$ProcessGroupId'
        $signalFunction | Should -Match 'Get-GuardianProcessStartIdentity'
        $signalFunction | Should -Match '\$LeaderStartIdentity'
        $signalFunction | Should -Match '\$Signal -ne 0'
        $source | Should -Match 'Test-GuardianLeaderLive'
        $source | Should -Match 'Test-GuardianProcessZombie'
        $source | Should -Match '"/proc/\$ProcessId/stat"'
        $source | Should -Match "\`$stat\[\`$nameEnd \+ 2\] -eq 'Z'"
        $source | Should -Match 'Invoke-GuardianGroupSignal[\s\S]+-Signal 15'
        $source | Should -Match 'Invoke-GuardianGroupSignal[\s\S]+-Signal 9'
    }

    It 'rejects invalid and role-mismatched PR targets in public watch wrappers' {
        foreach ($wrapper in @('Watch-DevPilotReviewer.ps1', 'Watch-DevPilotReviewHandler.ps1')) {
            $result = Invoke-TimedProcess -FilePath (Resolve-AgentPwshPath) -ArgumentList @(
                '-NoProfile', '-NonInteractive', '-File', (Join-Path (Split-Path $watchPath) $wrapper),
                '-PullRequestId', '0') -CaptureStdOut -CaptureStdErr -TimeoutSeconds 20
            $result.ExitCode | Should -Not -Be 0
            $result.StdErr | Should -Match 'PullRequestId must be greater than zero'
        }

        $invalid = Invoke-TimedProcess -FilePath (Resolve-AgentPwshPath) -ArgumentList @(
            '-NoProfile', '-NonInteractive', '-File', $watchPath,
            '-Agent', 'ReviewHandler', '-ReviewerPullRequestId', '0') `
            -CaptureStdOut -CaptureStdErr -TimeoutSeconds 20
        $invalid.ExitCode | Should -Not -Be 0
        $invalid.StdErr | Should -Match 'ReviewerPullRequestId\s+must be greater than zero'

        $mismatched = Invoke-TimedProcess -FilePath (Resolve-AgentPwshPath) -ArgumentList @(
            '-NoProfile', '-NonInteractive', '-File', $watchPath,
            '-Agent', 'ReviewHandler', '-ReviewerPullRequestId', '104') `
            -CaptureStdOut -CaptureStdErr -TimeoutSeconds 20
        $mismatched.ExitCode | Should -Not -Be 0
        $mismatched.StdErr | Should -Match 'ReviewerPullRequestId\s+requires\s+-Agent Reviewer or -Agent Both'
    }

    It 'creates broker authority only when a manual role is enabled' {
        $source = Get-Content -LiteralPath $watchPath -Raw
        $source | Should -Match 'if \(\$manualRoles\.Count -gt 0\)'
        $descriptorWrite = $source.IndexOf('[IO.File]::WriteAllText($brokerDescriptorPath')
        $manualGate = $source.LastIndexOf('if ($manualRoles.Count -gt 0)', $descriptorWrite)
        $manualGate | Should -BeGreaterThan -1
        $descriptorWrite | Should -BeGreaterThan $manualGate
        $source | Should -Match '\$brokerDescriptorPath\s*=\s*'''''
        $source | Should -Match 'if \(\$brokerDescriptorPath\)\s*\{\s*\$dashboardParameters\.BrokerDescriptorPath'
        $source | Should -Not -Match '& \$dashboardLauncher[^\r\n]*-BrokerDescriptorPath'
    }

    It 'rejects explicitly bound non-positive PR IDs for both roles' {
        foreach ($case in @(
                @{ Path = '..\src\Agents\reviewer\Start-ReviewerAgent.ps1'; Config = '..\samples\reviewer-ado.config.json' },
                @{ Path = '..\src\Agents\review-handler\Start-ReviewHandlerAgent.ps1'; Config = '..\samples\handler-ado.config.json' })) {
            $relativePath = $case.Path
            $source = Get-Content -LiteralPath (Resolve-Path (Join-Path $PSScriptRoot $relativePath)) -Raw
            $source | Should -Match "\`$PSBoundParameters\.ContainsKey\('PullRequestId'\)[\s\S]+PullRequestId must be greater than zero"
            $result = Invoke-TimedProcess -FilePath (Resolve-AgentPwshPath) -ArgumentList @(
                '-NoProfile', '-NonInteractive', '-File', (Resolve-Path (Join-Path $PSScriptRoot $relativePath)),
                '-DryRun', '-ConfigFile', (Resolve-Path (Join-Path $PSScriptRoot $case.Config)),
                '-PullRequestId', '0') -CaptureStdOut -CaptureStdErr -TimeoutSeconds 20
            $result.ExitCode | Should -Not -Be 0
            $result.StdErr | Should -Match 'PullRequestId must be greater than zero'
        }
    }

    It 'writes sealed reviewer files with create-new write-through atomic installation and fail-closed cleanup' {
        $source = Get-Content -LiteralPath $reviewerPath -Raw
        $writerStart = $source.IndexOf('function Write-ReviewerAtomicFile')
        $writerEnd = $source.IndexOf('function Write-ReviewerPreview', $writerStart)
        $writer = $source.Substring($writerStart, $writerEnd - $writerStart)
        $writer | Should -Match '\[IO\.FileMode\]::CreateNew'
        $writer | Should -Match '\[IO\.FileOptions\]::WriteThrough'
        $writer | Should -Match '\$stream\.Flush\(\$true\)'
        $writer | Should -Match 'SetUnixFileMode'
        $writer | Should -Match '\[IO\.File\]::Move\(\$tempPath, \$Path\)'
        $source | Should -Match 'Could not atomically persist the sealed review[\s\S]+delivery is blocked'
        $source | Should -Match '@\(\$artifactPath, \$path\)\s*\|\s*Where-Object'
    }

    It 'preserves the Markdown write failure when no artifact path exists yet' {
        $artifactPath = ''
        $path = Join-Path $TestDrive 'preview.md'
        $original = [IO.IOException]::new('markdown write failed')
        try {
            throw $original
        }
        catch {
            $caught = $_.Exception
            @($artifactPath, $path) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
                Remove-Item -Force -ErrorAction SilentlyContinue
        }
        [object]::ReferenceEquals($caught, $original) | Should -BeTrue
        $caught.Message | Should -BeExactly 'markdown write failed'
    }

    It 'removes authoritative artifacts and optional previews independently' {
        $source = Get-Content -LiteralPath $reviewerPath -Raw
        $source | Should -Not -Match 'Remove-Item -LiteralPath \$ArtifactPath, \$previewPath'
        $source | Should -Not -Match 'Remove-Item -LiteralPath \$artifactPath, \$previewPath'
        ([regex]::Matches($source,
                'Remove-Item -LiteralPath \$(?:A|a)rtifactPath -Force -ErrorAction Stop')).Count |
            Should -BeGreaterOrEqual 2
        $source | Should -Match 'if \(\$previewPath -and \(Test-Path -LiteralPath \$previewPath\)\)'
    }

    It 'persists a pending reviewer record before delivery and computes terminal state afterwards' {
        $source = Get-Content -LiteralPath $reviewerPath -Raw
        $pendingWrite = $source.IndexOf('deliveryPending     = $true', $source.IndexOf('function Invoke-ReviewerPullRequest'))
        $persistPending = $source.IndexOf('Set-AgentDurableRecords -Context $script:ReviewerDurableContext', $pendingWrite)
        $delivery = $source.IndexOf('$delivery = Invoke-ReviewerDelivery', $persistPending)
        $unresolved = $source.IndexOf('$unresolved = Get-ReviewerUnresolvedCapabilities', $delivery)
        $finalPending = $source.IndexOf('$deliveryPending = Test-ReviewerShouldKeepPendingPlan', $unresolved)
        $persistFinal = $source.IndexOf('Set-AgentDurableRecords -Context $script:ReviewerDurableContext', $finalPending)

        $pendingWrite | Should -BeGreaterThan -1
        $persistPending | Should -BeGreaterThan $pendingWrite
        $delivery | Should -BeGreaterThan $persistPending
        $unresolved | Should -BeGreaterThan $delivery
        $finalPending | Should -BeGreaterThan $unresolved
        $persistFinal | Should -BeGreaterThan $finalPending
        $source.Substring($persistPending, $delivery - $persistPending) |
            Should -Not -Match '\$unresolved|\$delivery\.TerminalAbort'
    }

    It 'keeps direct launches observe-only and forwards only the trusted descriptor tuple' {
        $source = Get-Content -LiteralPath (Resolve-Path "$PSScriptRoot\..\tools\Start-DevPilotDashboard.ps1") -Raw
        $source | Should -Match 'if \(\$descriptor\)'
        $source | Should -Match "'--broker-executable'"
        $source | Should -Match "'--broker-script'"
        $source | Should -Match "'--broker-descriptor'"
        $source | Should -Not -Match 'EnableApprovalVote|capabilityPolicyDigest|mandatoryDenies'
    }

    It 'binds broker and role scripts to the trusted toolkit paths' {
        $source = Get-Content -LiteralPath $brokerPath -Raw
        $source | Should -Match 'expectedRoleScripts'
        $source | Should -Match 'Assert-AgentTrustedFile'
        {
            Assert-AgentTrustedFile -Path $handlerPath -AllowedRoot (Split-Path $PSScriptRoot -Parent) `
                -ExpectedPath $reviewerPath
        } | Should -Throw '*not the expected file*'
    }

    It 'runs describe and shutdown through the broker process and exits without residue' {
        $repositoryRoot = (Resolve-Path "$PSScriptRoot\..").Path
        $suiteRoot = Join-Path $TestDrive 'broker-integration'
        $stateRoot = Resolve-AgentTrustedRoot -Path (Join-Path $suiteRoot 'watch') `
            -Kind watch-state -RepositoryRoot $repositoryRoot -Create
        $durableRoot = Resolve-AgentTrustedRoot -Path (Join-Path $suiteRoot 'durable') `
            -Kind durable-state -RepositoryRoot $repositoryRoot -DisallowedRoots @($stateRoot) -Create
        $leaseRoot = Resolve-AgentTrustedRoot -Path (Join-Path $suiteRoot 'leases') `
            -Kind lease -RepositoryRoot $repositoryRoot -DisallowedRoots @($stateRoot, $durableRoot) -Create
        $descriptorPath = Join-Path $stateRoot 'broker.descriptor.v1.json'
        @{
            schemaVersion = 1
            ownerProcessId = $PID
            stateRoot = $stateRoot
            durableStateRoot = $durableRoot
            leaseRoot = $leaseRoot
            operatorAlias = 'integration-test'
            roles = @{}
        } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $descriptorPath -Encoding utf8NoBOM
        if (-not $IsWindows) {
            [IO.File]::SetUnixFileMode($descriptorPath,
                [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite)
        }
        [void](Assert-AgentTrustedFile -Path $descriptorPath -AllowedRoot $stateRoot `
            -ExpectedPath $descriptorPath -Private)

        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        # Resolve-AgentPwshPath already guards against Get-Command returning
        # multiple Application matches (common on Linux/macOS runners, where
        # pwsh is reachable via several PATH entries such as
        # /opt/microsoft/powershell/7/pwsh, /usr/bin/pwsh, and /bin/pwsh) -
        # reuse it instead of re-deriving the path inline.
        $startInfo.FileName = Resolve-AgentPwshPath
        foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-File',
                $brokerPath, '-DescriptorPath', $descriptorPath)) {
            [void]$startInfo.ArgumentList.Add($argument)
        }
        $startInfo.UseShellExecute = $false
        $startInfo.RedirectStandardInput = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $process = [Diagnostics.Process]::new()
        $process.StartInfo = $startInfo
        [void]$process.Start()
        try {
            $describeId = [Guid]::NewGuid().ToString('D')
            $shutdownId = [Guid]::NewGuid().ToString('D')
            $process.StandardInput.WriteLine((ConvertTo-AgentCanonicalJson @{
                        schemaVersion = 1; requestId = $describeId; operation = 'describe'
                        role = 'reviewer'; pullRequestId = 1; repositoryKey = 'v1:github:1'
                    }))
            $describeResponseTask = $process.StandardOutput.ReadLineAsync()
            $describeResponseTask.Wait(10000) | Should -BeTrue `
                -Because 'the broker must process a request while stdin remains open'
            $describeResponse = $describeResponseTask.Result | ConvertFrom-Json -AsHashtable
            $describeResponse.requestId | Should -BeExactly $describeId
            $describeResponse.operation | Should -BeExactly 'rejected'
            $describeResponse.code | Should -BeExactly 'role-not-allowed'

            $process.StandardInput.WriteLine((ConvertTo-AgentCanonicalJson @{
                        schemaVersion = 1; requestId = $shutdownId; operation = 'shutdown'
                    }))
            $shutdownResponseTask = $process.StandardOutput.ReadLineAsync()
            $shutdownResponseTask.Wait(10000) | Should -BeTrue `
                -Because 'the broker must process the next request while stdin remains open'
            $shutdownResponse = $shutdownResponseTask.Result | ConvertFrom-Json -AsHashtable
            $shutdownResponse.requestId | Should -BeExactly $shutdownId
            $shutdownResponse.operation | Should -BeExactly 'shutdown-complete'

            $process.StandardInput.Close()
            $process.WaitForExit(15000) | Should -BeTrue
            $stderr = $process.StandardError.ReadToEnd()
            $process.ExitCode | Should -Be 0 -Because $stderr
            Test-Path (Join-Path $stateRoot 'manual-dispatch') | Should -BeFalse
        }
        finally {
            if (-not $process.HasExited) { $process.Kill($true); [void]$process.WaitForExit(5000) }
            $process.Dispose()
        }
    }

    It 'shares a side-effect-free capability profile helper between describe and profile' {
        $source = Get-Content -LiteralPath $brokerPath -Raw
        $source | Should -Match "'profile' \{ Invoke-Profile \`$request \}"

        $helperBody = [regex]::Match($source, '(?s)function Get-BrokerCapabilityProfile \{.*?\n\}').Value
        $helperBody | Should -Not -BeNullOrEmpty
        $helperBody | Should -Not -Match 'New-ConfigSnapshot'
        $helperBody | Should -Not -Match '\$drafts\['

        $profileBody = [regex]::Match($source, '(?s)function Invoke-Profile \{.*?\n\}').Value
        $profileBody | Should -Not -BeNullOrEmpty
        $profileBody | Should -Match 'Get-BrokerCapabilityProfile'
        $profileBody | Should -Not -Match 'New-ConfigSnapshot'
        $profileBody | Should -Not -Match '\$drafts\['
        $profileBody | Should -Not -Match 'dispatchDraftId\s*='
        $profileBody | Should -Match "operation = 'capability-profile'"
        $profileBody | Should -Match 'role = \$profile\.Role'

        $describeBody = [regex]::Match($source, '(?s)function Invoke-Describe \{.*?\n\}').Value
        $describeBody | Should -Not -BeNullOrEmpty
        $describeBody | Should -Match 'Get-BrokerCapabilityProfile'
        $describeBody | Should -Match 'New-ConfigSnapshot'
        $describeBody | Should -Match '\$drafts\['
        $describeBody | Should -Match "operation = 'capability-summary'"
        $describeBody | Should -Match 'role = \$role'
    }

    It 'emits killSwitchExpiresAtUtc on describe, profile, and set-kill-switch responses, and set-kill-switch verifies the actual read-back state' {
        # Protocol-shape coverage (issue #105 PR3 completion): describe/profile must surface the
        # same Override.KillSwitchExpiresAtUtc Resolve-AgentEffectiveCapabilitySettings now returns
        # alongside KillSwitchActive, and set-kill-switch (which has no PR-scoped Override object to
        # read from) must read back the actual sentinel state via
        # Get-AgentCapabilityOverrideKillSwitchState under the same lock it already holds for
        # Enable-/Disable-AgentCapabilityOverrideKillSwitch -- and emit ITS Active/ExpiresAtUtc,
        # never the request's own `enabled` value, after verifying the requested transition
        # actually happened (issue #105 PR3 completion: never acknowledge enabled=true when
        # inactive).
        $source = Get-Content -LiteralPath $brokerPath -Raw

        $profileBody = [regex]::Match($source, '(?s)function Invoke-Profile \{.*?\n\}').Value
        $profileBody | Should -Match 'killSwitchExpiresAtUtc\s*=\s*\$profile\.Override\.KillSwitchExpiresAtUtc'

        $describeBody = [regex]::Match($source, '(?s)function Invoke-Describe \{.*?\n\}').Value
        $describeBody | Should -Match 'killSwitchExpiresAtUtc\s*=\s*\$profile\.Override\.KillSwitchExpiresAtUtc'

        $setKillSwitchBody = [regex]::Match($source, '(?s)function Invoke-SetKillSwitch \{.*?\n\}').Value
        $setKillSwitchBody | Should -Not -BeNullOrEmpty
        $setKillSwitchBody | Should -Match 'Get-AgentCapabilityOverrideKillSwitchState'
        $setKillSwitchBody | Should -Match "operation = 'kill-switch-applied'"
        $setKillSwitchBody | Should -Match 'killSwitchExpiresAtUtc\s*=\s*\$state\.ExpiresAtUtc'
        # Verified read-back, never the raw request value (issue #105 PR3 completion).
        $setKillSwitchBody | Should -Match 'enabled\s*=\s*\[bool\]\$state\.Active'
        $setKillSwitchBody | Should -Not -Match 'enabled\s*=\s*\[bool\]\$enabledValue'
        $setKillSwitchBody | Should -Match '\$state\.Active -ne \$enabledValue'
    }

    It 'keeps the read-only profile operation side-effect-free across repeated calls' {
        $repositoryRoot = (Resolve-Path "$PSScriptRoot\..").Path
        $suiteRoot = Join-Path $TestDrive 'broker-profile-integration'
        $stateRoot = Resolve-AgentTrustedRoot -Path (Join-Path $suiteRoot 'watch') `
            -Kind watch-state -RepositoryRoot $repositoryRoot -Create
        $durableRoot = Resolve-AgentTrustedRoot -Path (Join-Path $suiteRoot 'durable') `
            -Kind durable-state -RepositoryRoot $repositoryRoot -DisallowedRoots @($stateRoot) -Create
        $leaseRoot = Resolve-AgentTrustedRoot -Path (Join-Path $suiteRoot 'leases') `
            -Kind lease -RepositoryRoot $repositoryRoot -DisallowedRoots @($stateRoot, $durableRoot) -Create
        $descriptorPath = Join-Path $stateRoot 'broker.descriptor.v1.json'
        @{
            schemaVersion = 1
            ownerProcessId = $PID
            stateRoot = $stateRoot
            durableStateRoot = $durableRoot
            leaseRoot = $leaseRoot
            operatorAlias = 'integration-test'
            roles = @{}
        } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $descriptorPath -Encoding utf8NoBOM
        if (-not $IsWindows) {
            [IO.File]::SetUnixFileMode($descriptorPath,
                [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite)
        }
        [void](Assert-AgentTrustedFile -Path $descriptorPath -AllowedRoot $stateRoot `
            -ExpectedPath $descriptorPath -Private)

        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = Resolve-AgentPwshPath
        foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-File',
                $brokerPath, '-DescriptorPath', $descriptorPath)) {
            [void]$startInfo.ArgumentList.Add($argument)
        }
        $startInfo.UseShellExecute = $false
        $startInfo.RedirectStandardInput = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $process = [Diagnostics.Process]::new()
        $process.StartInfo = $startInfo
        [void]$process.Start()
        try {
            # Repeated profile requests (simulating a Settings refresh and close/reopen) must never
            # create the manual-dispatch draft directory -- each is rejected the same way describe()
            # would be for this unconfigured role, proving the read-only path never reaches
            # New-ConfigSnapshot regardless of how many times it is called.
            for ($i = 0; $i -lt 3; $i++) {
                $profileId = [Guid]::NewGuid().ToString('D')
                $process.StandardInput.WriteLine((ConvertTo-AgentCanonicalJson @{
                            schemaVersion = 1; requestId = $profileId; operation = 'profile'
                            role = 'reviewer'; pullRequestId = 1; repositoryKey = 'v1:github:1'
                        }))
                $profileResponseTask = $process.StandardOutput.ReadLineAsync()
                $profileResponseTask.Wait(10000) | Should -BeTrue `
                    -Because 'the broker must process each repeated profile request while stdin remains open'
                $profileResponse = $profileResponseTask.Result | ConvertFrom-Json -AsHashtable
                $profileResponse.requestId | Should -BeExactly $profileId
                $profileResponse.operation | Should -BeExactly 'rejected'
                $profileResponse.code | Should -BeExactly 'role-not-allowed'
                Test-Path (Join-Path $stateRoot 'manual-dispatch') | Should -BeFalse
            }

            $shutdownId = [Guid]::NewGuid().ToString('D')
            $process.StandardInput.WriteLine((ConvertTo-AgentCanonicalJson @{
                        schemaVersion = 1; requestId = $shutdownId; operation = 'shutdown'
                    }))
            $shutdownResponseTask = $process.StandardOutput.ReadLineAsync()
            $shutdownResponseTask.Wait(10000) | Should -BeTrue `
                -Because 'the broker must process the next request while stdin remains open'
            $shutdownResponse = $shutdownResponseTask.Result | ConvertFrom-Json -AsHashtable
            $shutdownResponse.requestId | Should -BeExactly $shutdownId
            $shutdownResponse.operation | Should -BeExactly 'shutdown-complete'

            $process.StandardInput.Close()
            $process.WaitForExit(15000) | Should -BeTrue
            $stderr = $process.StandardError.ReadToEnd()
            $process.ExitCode | Should -Be 0 -Because $stderr
            Test-Path (Join-Path $stateRoot 'manual-dispatch') | Should -BeFalse
        }
        finally {
            if (-not $process.HasExited) { $process.Kill($true); [void]$process.WaitForExit(5000) }
            $process.Dispose()
        }
    }

    It 'rejects case-variant roles (Reviewer, REVIEWER) consistently across describe, profile, preview-narrowing, and set-kill-switch' {
        # issue #105 PR3 completion (blocker 3): Get-RoleDescriptor is the single shared lookup
        # behind describe/profile/preview-narrowing (via Get-BrokerCapabilityProfile) -- plain
        # PowerShell '-notin'/Hashtable key lookup are both case-insensitive by default, so this
        # proves the fix holds at the real wire boundary for every operation reachable at the
        # protocol level without first minting a genuine previewToken (apply-narrowing's own
        # independent '-cnotin' role guard, which runs before Get-RoleDescriptor and requires a
        # real preview-narrowing round trip first, is instead asserted by source inspection in the
        # next test). set-kill-switch keeps its own pre-existing '-cnotin' guard (added as a
        # stopgap before this fix existed) and so still rejects with 'narrowing-invalid' rather
        # than 'role-not-allowed' -- both are correct rejections; the point proven here is that
        # none of the five operations ever resolves 'Reviewer'/'REVIEWER' to the real 'reviewer'
        # role.
        $repositoryRoot = (Resolve-Path "$PSScriptRoot\..").Path
        $suiteRoot = Join-Path $TestDrive 'broker-role-casing-integration'
        $stateRoot = Resolve-AgentTrustedRoot -Path (Join-Path $suiteRoot 'watch') `
            -Kind watch-state -RepositoryRoot $repositoryRoot -Create
        $durableRoot = Resolve-AgentTrustedRoot -Path (Join-Path $suiteRoot 'durable') `
            -Kind durable-state -RepositoryRoot $repositoryRoot -DisallowedRoots @($stateRoot) -Create
        $leaseRoot = Resolve-AgentTrustedRoot -Path (Join-Path $suiteRoot 'leases') `
            -Kind lease -RepositoryRoot $repositoryRoot -DisallowedRoots @($stateRoot, $durableRoot) -Create
        $descriptorPath = Join-Path $stateRoot 'broker.descriptor.v1.json'
        @{
            schemaVersion = 1
            ownerProcessId = $PID
            stateRoot = $stateRoot
            durableStateRoot = $durableRoot
            leaseRoot = $leaseRoot
            operatorAlias = 'integration-test'
            roles = @{}
        } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $descriptorPath -Encoding utf8NoBOM
        if (-not $IsWindows) {
            [IO.File]::SetUnixFileMode($descriptorPath,
                [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite)
        }
        [void](Assert-AgentTrustedFile -Path $descriptorPath -AllowedRoot $stateRoot `
            -ExpectedPath $descriptorPath -Private)

        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = Resolve-AgentPwshPath
        foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-File',
                $brokerPath, '-DescriptorPath', $descriptorPath)) {
            [void]$startInfo.ArgumentList.Add($argument)
        }
        $startInfo.UseShellExecute = $false
        $startInfo.RedirectStandardInput = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $process = [Diagnostics.Process]::new()
        $process.StartInfo = $startInfo
        [void]$process.Start()
        try {
            $expectedCode = [ordered]@{
                'describe' = 'role-not-allowed'
                'profile' = 'role-not-allowed'
                'preview-narrowing' = 'role-not-allowed'
                'set-kill-switch' = 'narrowing-invalid'
            }
            foreach ($caseVariant in @('Reviewer', 'REVIEWER')) {
                foreach ($operation in @('describe', 'profile', 'preview-narrowing', 'set-kill-switch')) {
                    $requestId = [Guid]::NewGuid().ToString('D')
                    $body = [ordered]@{
                        schemaVersion = 1; requestId = $requestId; operation = $operation
                        role = $caseVariant; repositoryKey = 'v1:github:1'
                    }
                    if ($operation -ne 'set-kill-switch') { $body['pullRequestId'] = 1 }
                    if ($operation -eq 'preview-narrowing') {
                        $body['scope'] = 'user'; $body['capability'] = 'EnableSummaryComment'; $body['action'] = 'off'
                    }
                    if ($operation -eq 'set-kill-switch') { $body['enabled'] = $true }
                    $process.StandardInput.WriteLine((ConvertTo-AgentCanonicalJson $body))
                    $task = $process.StandardOutput.ReadLineAsync()
                    $task.Wait(10000) | Should -BeTrue -Because "the broker must process $operation/$caseVariant while stdin remains open"
                    $response = $task.Result | ConvertFrom-Json -AsHashtable
                    $response.requestId | Should -BeExactly $requestId
                    $response.operation | Should -BeExactly 'rejected'
                    $response.code | Should -BeExactly $expectedCode[$operation] -Because "$operation must reject role '$caseVariant'"
                }
            }
            Test-Path (Join-Path $stateRoot 'manual-dispatch') | Should -BeFalse

            $shutdownId = [Guid]::NewGuid().ToString('D')
            $process.StandardInput.WriteLine((ConvertTo-AgentCanonicalJson @{
                        schemaVersion = 1; requestId = $shutdownId; operation = 'shutdown'
                    }))
            $shutdownResponseTask = $process.StandardOutput.ReadLineAsync()
            $shutdownResponseTask.Wait(10000) | Should -BeTrue `
                -Because 'the broker must process the next request while stdin remains open'
            $shutdownResponse = $shutdownResponseTask.Result | ConvertFrom-Json -AsHashtable
            $shutdownResponse.requestId | Should -BeExactly $shutdownId
            $shutdownResponse.operation | Should -BeExactly 'shutdown-complete'

            $process.StandardInput.Close()
            $process.WaitForExit(15000) | Should -BeTrue
            $stderr = $process.StandardError.ReadToEnd()
            $process.ExitCode | Should -Be 0 -Because $stderr
        }
        finally {
            if (-not $process.HasExited) { $process.Kill($true); [void]$process.WaitForExit(5000) }
            $process.Dispose()
        }
    }

    It 'Get-RoleDescriptor performs an exact-case role check and case-sensitive retrieval; apply-narrowing and set-kill-switch each keep their own independent case-sensitive role guard' {
        $source = Get-Content -LiteralPath $brokerPath -Raw
        $roleDescriptorBody = [regex]::Match($source, '(?s)function Get-RoleDescriptor \{.*?\n\}').Value
        $roleDescriptorBody | Should -Not -BeNullOrEmpty
        $roleDescriptorBody | Should -Match '\$Role -cnotin @\(''reviewer'', ''review-handler''\)'
        $roleDescriptorBody | Should -Not -Match '\$Role -notin '
        $roleDescriptorBody | Should -Match '-ceq \$Role'

        $applyBody = [regex]::Match($source, '(?s)function Invoke-ApplyNarrowing \{.*?\n\}').Value
        $applyBody | Should -Not -BeNullOrEmpty
        $applyBody | Should -Match '\$role -cnotin @\(''reviewer'', ''review-handler''\)'

        $setKillSwitchBody = [regex]::Match($source, '(?s)function Invoke-SetKillSwitch \{.*?\n\}').Value
        $setKillSwitchBody | Should -Not -BeNullOrEmpty
        $setKillSwitchBody | Should -Match '\$role -cnotin @\(''reviewer'', ''review-handler''\)'
    }

    It 'cleans guardian files before child registration on Unix' -Skip:$IsWindows {
        $runtimeRoot = Join-Path $TestDrive 'guardian-runtime'
        New-Item -ItemType Directory -Path $runtimeRoot | Out-Null
        [IO.File]::SetUnixFileMode($runtimeRoot,
            [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite -bor
            [IO.UnixFileMode]::UserExecute)
        $token = 'a' * 32
        $registration = Join-Path $runtimeRoot "guardian-$token.json"
        @{
            token = $token
            paths = @('operator-context.txt')
        } | ConvertTo-Json -Compress | Set-Content -LiteralPath $registration -Encoding utf8NoBOM
        [IO.File]::SetUnixFileMode($registration,
            [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite)
        $deadPid = 2147483647
        & pwsh -NoLogo -NoProfile -NonInteractive -File $guardianPath `
            -RuntimeRoot $runtimeRoot -BrokerProcessId $deadPid -BrokerStartIdentity 'utc:1' `
            -Token $token -DeadlineSeconds 2
        $LASTEXITCODE | Should -Be 0
        Get-ChildItem -LiteralPath $runtimeRoot -Force | Should -BeNullOrEmpty
    }

    It 'keeps the Unix guardian through prompt deletion and kills the accepted group after broker death' -Skip:$IsWindows {
        $runtimeRoot = Join-Path $TestDrive 'guardian-accepted-runtime'
        New-Item -ItemType Directory -Path $runtimeRoot | Out-Null
        [IO.File]::SetUnixFileMode($runtimeRoot,
            [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite -bor [IO.UnixFileMode]::UserExecute)
        $broker = Start-Process -FilePath (Resolve-AgentPwshPath) `
            -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 30') -PassThru
        $childOut = Join-Path $runtimeRoot 'child.stdout'
        $childErr = Join-Path $runtimeRoot 'child.stderr'
        $child = New-AgentRedirectedProcess -FilePath (Resolve-AgentPwshPath) `
            -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 30') `
            -StandardOutputPath $childOut -StandardErrorPath $childErr
        $token = 'b' * 32
        $guardianOut = Join-Path $runtimeRoot 'guardian.stdout'
        $guardianErr = Join-Path $runtimeRoot 'guardian.stderr'
        $guardian = New-AgentRedirectedProcess -FilePath (Resolve-AgentPwshPath) `
            -ArgumentList @('-NoProfile', '-File', $guardianPath, '-RuntimeRoot', $runtimeRoot,
                '-BrokerProcessId', [string]$broker.Id, '-BrokerStartIdentity',
                (Get-AgentProcessStartIdentity -Process $broker), '-Token', $token,
                '-DeadlineSeconds', '30', '-Verbose') `
            -StandardOutputPath $guardianOut -StandardErrorPath $guardianErr
        try {
            $ready = Join-Path $runtimeRoot "guardian-$token.ready"
            # Two independent handshake steps (ready, then registered) must each get
            # their own deadline: reusing a single deadline across both waits (as this
            # test previously did) starves the second wait whenever the first wait
            # consumes most of the budget under CI scheduling delay - e.g. guardian's
            # one-time Add-Type compile of the libc P/Invoke shim can itself take a
            # meaningful slice of a tight budget on constrained Ubuntu runners. This
            # mirrors the two-deadline pattern in Publish-ProtectedPrompt.
            $readyDeadline = [DateTime]::UtcNow.AddSeconds(10)
            while (-not (Test-Path -LiteralPath $ready) -and -not $guardian.Process.HasExited -and
                [DateTime]::UtcNow -lt $readyDeadline) {
                Start-Sleep -Milliseconds 25
            }
            $guardianReady = Test-Path -LiteralPath $ready
            $readyDiagnostics = if (-not $guardianReady) { Complete-AgentRedirectedProcess $guardian } else { $null }
            $guardianReady | Should -BeTrue -Because (
                "the guardian must signal ready before the registration handshake begins" +
                $(if ($readyDiagnostics) { "; guardian stderr: $($readyDiagnostics.SafeErrorTail)" }))
            $prompt = Join-Path $runtimeRoot 'operator-context.txt'
            Set-Content -LiteralPath $prompt -Value 'secret' -Encoding utf8NoBOM
            @{
                token = $token; childProcessId = $child.Process.Id
                childLeaderStartIdentity = Get-AgentProcessStartIdentity -Process $child.Process
                paths = @('operator-context.txt')
            } | ConvertTo-Json -Compress | Set-Content `
                -LiteralPath (Join-Path $runtimeRoot "guardian-$token.json") -Encoding utf8NoBOM
            $registered = Join-Path $runtimeRoot "guardian-$token.registered"
            $registeredDeadline = [DateTime]::UtcNow.AddSeconds(10)
            while (-not (Test-Path -LiteralPath $registered) -and -not $guardian.Process.HasExited -and
                [DateTime]::UtcNow -lt $registeredDeadline) {
                Start-Sleep -Milliseconds 25
            }
            $guardianRegistered = Test-Path -LiteralPath $registered
            $registeredDiagnostics = if (-not $guardianRegistered) { Complete-AgentRedirectedProcess $guardian } else { $null }
            $guardianRegistered | Should -BeTrue -Because (
                "the guardian must complete the registration handshake before the prompt is deleted" +
                $(if ($registeredDiagnostics) { "; guardian stderr: $($registeredDiagnostics.SafeErrorTail)" }))
            Remove-Item -LiteralPath $prompt -Force
            Start-Sleep -Milliseconds 250
            $guardian.Process.HasExited | Should -BeFalse
            $broker.Kill()
            $broker.WaitForExit(5000) | Should -BeTrue
            # This test runner owns the child, unlike the production broker.
            # Observe and reap it so the guardian does not see a zombie leader.
            $childDeadline = [DateTime]::UtcNow.AddSeconds(10)
            while (-not $child.Process.HasExited -and [DateTime]::UtcNow -lt $childDeadline) {
                Start-Sleep -Milliseconds 25
            }
            $childExited = $child.Process.HasExited
            $childKillDiagnostics = if (-not $childExited) { Complete-AgentRedirectedProcess $guardian } else { $null }
            $brokerProbe = Get-Process -Id $broker.Id -ErrorAction SilentlyContinue
            $brokerProcStat = if ($IsLinux -and (Test-Path -LiteralPath "/proc/$($broker.Id)/stat")) {
                Get-Content -LiteralPath "/proc/$($broker.Id)/stat" -Raw
            } else { '<absent>' }
            $childProcStat = if ($IsLinux -and (Test-Path -LiteralPath "/proc/$($child.Process.Id)/stat")) {
                Get-Content -LiteralPath "/proc/$($child.Process.Id)/stat" -Raw
            } else { '<absent>' }
            $guardianTracePath = Join-Path $runtimeRoot "guardian-$token.trace"
            $guardianTrace = if (Test-Path -LiteralPath $guardianTracePath) {
                Get-Content -LiteralPath $guardianTracePath -Raw
            } else { '<absent>' }
            $childExited | Should -BeTrue -Because (
                "the guardian must terminate the accepted child group after the broker dies" +
                $(if ($childKillDiagnostics) {
                        "; guardian stdout: $($childKillDiagnostics.SafeOutputTail); " +
                        "guardian stderr: $($childKillDiagnostics.SafeErrorTail)"
                    }) +
                "; guardian exited: $($guardian.Process.HasExited); " +
                "broker probe: $($null -ne $brokerProbe); broker stat: $brokerProcStat; " +
                "child stat: $childProcStat; guardian trace: $guardianTrace")
            $guardian.Process.WaitForExit(10000) | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $runtimeRoot "guardian-$token.json") | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $runtimeRoot "guardian-$token.ready") | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $runtimeRoot "guardian-$token.registered") | Should -BeFalse
        }
        finally {
            if (-not $broker.HasExited) { $broker.Kill(); [void]$broker.WaitForExit(5000) }
            if (-not $guardian.Process.HasExited) { Stop-ProcessTree $guardian.Process }
            if (-not $child.Process.HasExited) { Stop-ProcessTree $child.Process }
            [void](Complete-AgentRedirectedProcess $guardian)
            [void](Complete-AgentRedirectedProcess $child)
            $broker.Dispose()
        }
    }

    It 'never signals a reused Unix process group when leader start identity mismatches' -Skip:$IsWindows {
        $runtimeRoot = Join-Path $TestDrive 'guardian-stale-runtime'
        New-Item -ItemType Directory -Path $runtimeRoot | Out-Null
        [IO.File]::SetUnixFileMode($runtimeRoot,
            [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite -bor [IO.UnixFileMode]::UserExecute)
        $token = 'c' * 32
        # The recorded "leader" must be a real process that owns its own Unix
        # process group (via New-AgentRedirectedProcess's setsid wrapper), not
        # this test-runner's own $PID: the runner process is frequently *not*
        # its own process group leader (e.g. under a CI job shell), so a
        # liveness probe against -$PID would report the group absent and the
        # guardian would exit almost immediately instead of exercising the
        # stale-identity refusal path for the full deadline.
        $stdout = Join-Path $runtimeRoot 'stale-leader.stdout.log'
        $stderr = Join-Path $runtimeRoot 'stale-leader.stderr.log'
        $leader = New-AgentRedirectedProcess -FilePath (Resolve-AgentPwshPath) `
            -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 30') `
            -StandardOutputPath $stdout -StandardErrorPath $stderr
        @{
            token = $token
            childProcessId = $leader.Process.Id
            childLeaderStartIdentity = 'utc:1'
            paths = @('operator-context.txt')
        } | ConvertTo-Json -Compress | Set-Content `
            -LiteralPath (Join-Path $runtimeRoot "guardian-$token.json") -Encoding utf8NoBOM
        [IO.File]::SetUnixFileMode((Join-Path $runtimeRoot "guardian-$token.json"),
            [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite)
        try {
            $result = Invoke-TimedProcess -FilePath (Resolve-AgentPwshPath) -ArgumentList @(
                '-NoLogo', '-NoProfile', '-NonInteractive', '-File', $guardianPath,
                '-RuntimeRoot', $runtimeRoot, '-BrokerProcessId', '2147483647',
                '-BrokerStartIdentity', 'utc:1',
                '-Token', $token, '-DeadlineSeconds', '2') -CaptureStdOut -CaptureStdErr -TimeoutSeconds 2
            $result.TimedOut | Should -BeTrue
            $leader.Process.HasExited | Should -BeFalse
        }
        finally {
            if (-not $leader.Process.HasExited) { Stop-ProcessTree $leader.Process }
            [void](Complete-AgentRedirectedProcess $leader)
        }
    }

    # ------------------------------------------------------------------
    # issue #105 PR5 (broker-issuer anchor)
    # ------------------------------------------------------------------
    # The anonymous-pipe/HMAC attestation alone proves a child can read a secret
    # handed down an OS-inherited handle -- it never proved the handle actually
    # came from a real broker. These tests cover, in order: the pure procfs
    # parser (static fixtures, any host), the two OS-ancestry probes across a
    # REAL spawned process boundary (not mocked), Assert-AgentBrokerProcessAnchor's
    # full decision logic (OS-truth probes mocked -- deliberately, and only
    # those two, since faking "this process's real OS parent is running the one
    # pinned broker script" for a genuine positive case would otherwise require
    # actually running the production broker end-to-end through its full
    # draft/policy/provider pipeline; everything else here -- trusted-root
    # resolution, descriptor I/O, canonical digesting, script hashing, role-pin
    # checks -- is completely real, unmocked), and finally a real adversarial
    # process spawn proving the whole chain rejects a same-user forger who
    # truthfully reports their own PID/start-time/descriptor/script hash.

    It 'ConvertFrom-AgentProcStatPpid parses a well-formed procfs stat line, including a comm field containing spaces and parentheses' {
        ConvertFrom-AgentProcStatPpid -StatText '4021 (my (weird) proc) S 4000 4021 4021 0 -1 4194304 0 0 0 0 0 0 0 0 20 0 1 0 0' |
            Should -Be 4000
    }

    It 'ConvertFrom-AgentProcStatPpid throws on a stat line with no comm field terminator' {
        { ConvertFrom-AgentProcStatPpid -StatText '4021 unterminated S 4000' } | Should -Throw '*comm field terminator*'
    }

    It 'ConvertFrom-AgentProcStatPpid throws when the ppid field is not a plain integer' {
        { ConvertFrom-AgentProcStatPpid -StatText '4021 (proc) S notanumber 4021 4021' } |
            Should -Throw '*ppid field is not a plain integer*'
    }

    It 'Get-AgentImmediateParentProcessId and Get-AgentProcessCommandLine identify a real spawned parent across a real OS process boundary' {
        # At minimum: spawn a trusted "broker" harness process that itself spawns
        # a child verifier, and prove the verifier's independently-derived live
        # parent PID and command line actually point back at the harness -- the
        # exact real-OS-fact primitive Assert-AgentBrokerProcessAnchor anchors on.
        $suiteRoot = Join-Path $TestDrive 'ancestry-integration'
        New-Item -ItemType Directory -Path $suiteRoot -Force | Out-Null
        $modulePath = (Resolve-Path "$PSScriptRoot\..\src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1").Path
        $childScriptPath = Join-Path $suiteRoot 'child-verifier.ps1'
        $harnessScriptPath = Join-Path $suiteRoot 'harness-broker-stand-in.ps1'
        Set-Content -LiteralPath $childScriptPath -Encoding utf8NoBOM -Value @'
param([Parameter(Mandatory)][string]$ModulePath, [Parameter(Mandatory)][string]$OutputPath)
Import-Module $ModulePath -Force
$parentPid = Get-AgentImmediateParentProcessId
$parentCommandLine = Get-AgentProcessCommandLine -ProcessId $parentPid
[IO.File]::WriteAllText($OutputPath, (ConvertTo-Json @{ ParentPid = $parentPid; ParentCommandLine = $parentCommandLine } -Compress))
'@
        Set-Content -LiteralPath $harnessScriptPath -Encoding utf8NoBOM -Value @'
param(
    [Parameter(Mandatory)][string]$ModulePath,
    [Parameter(Mandatory)][string]$ChildScriptPath,
    [Parameter(Mandatory)][string]$OutputPath,
    [Parameter(Mandatory)][string]$ChildStdOutPath,
    [Parameter(Mandatory)][string]$ChildStdErrPath,
    [Parameter(Mandatory)][string]$PwshPath
)
Import-Module $ModulePath -Force
$child = New-AgentRedirectedProcess -FilePath $PwshPath -ArgumentList @(
    '-NoLogo', '-NoProfile', '-NonInteractive', '-File', $ChildScriptPath,
    '-ModulePath', $ModulePath, '-OutputPath', $OutputPath
) -StandardOutputPath $ChildStdOutPath -StandardErrorPath $ChildStdErrPath
$child.Process.WaitForExit(15000) | Out-Null
[void](Complete-AgentRedirectedProcess $child)
'@
        $resultPath = Join-Path $suiteRoot 'result.json'
        $childStdOut = Join-Path $suiteRoot 'child.stdout.log'
        $childStdErr = Join-Path $suiteRoot 'child.stderr.log'
        $harnessStdOut = Join-Path $suiteRoot 'harness.stdout.log'
        $harnessStdErr = Join-Path $suiteRoot 'harness.stderr.log'
        $pwshPath = Resolve-AgentPwshPath
        $harness = New-AgentRedirectedProcess -FilePath $pwshPath -ArgumentList @(
            '-NoLogo', '-NoProfile', '-NonInteractive', '-File', $harnessScriptPath,
            '-ModulePath', $modulePath, '-ChildScriptPath', $childScriptPath,
            '-OutputPath', $resultPath, '-ChildStdOutPath', $childStdOut, '-ChildStdErrPath', $childStdErr,
            '-PwshPath', $pwshPath
        ) -StandardOutputPath $harnessStdOut -StandardErrorPath $harnessStdErr
        try {
            $exited = $harness.Process.WaitForExit(20000)
            $harnessDiagnostics = if (-not $exited -or -not (Test-Path -LiteralPath $resultPath)) {
                Complete-AgentRedirectedProcess $harness
            } else { $null }
            $exited | Should -BeTrue -Because (
                "the harness must spawn and wait on its child verifier within budget" +
                $(if ($harnessDiagnostics) { "; harness stderr: $($harnessDiagnostics.SafeErrorTail)" }))
            (Test-Path -LiteralPath $resultPath) | Should -BeTrue -Because (
                "the child verifier must have written its result" +
                $(if ($harnessDiagnostics) { "; harness stderr: $($harnessDiagnostics.SafeErrorTail)" }))
            $result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
            $result.ParentPid | Should -Be $harness.Process.Id -Because (
                "the child verifier's real OS parent must be the harness process that spawned it, " +
                "exactly as a manual-dispatch child's parent must be the broker")
            $result.ParentCommandLine | Should -Match ([regex]::Escape($harnessScriptPath)) -Because (
                "the parent's live command line must actually name the script it is running, " +
                "not merely share its PID")
        }
        finally {
            if (-not $harness.Process.HasExited) { Stop-ProcessTree $harness.Process; [void]$harness.Process.WaitForExit(5000) }
            [void](Complete-AgentRedirectedProcess $harness)
        }
    }

    It 'Assert-AgentBrokerProcessAnchor accepts a manifest whose broker-origin claims all match independently-verified live state' {
        $repositoryRoot = (Resolve-Path "$PSScriptRoot\..").Path
        $suiteRoot = Join-Path $TestDrive 'anchor-happy-path'
        $stateRoot = Resolve-AgentTrustedRoot -Path (Join-Path $suiteRoot 'watch') -Kind watch-state `
            -RepositoryRoot $repositoryRoot -Create
        $descriptorPath = Join-Path $stateRoot 'broker.descriptor.v1.json'
        @{ schemaVersion = 1; ownerProcessId = $PID; roles = @{ reviewer = @{ scriptPath = $reviewerPath } } } |
            ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $descriptorPath -Encoding utf8NoBOM
        if (-not $IsWindows) {
            [IO.File]::SetUnixFileMode($descriptorPath, [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite)
        }
        $liveDescriptor = Get-Content -LiteralPath $descriptorPath -Raw -Encoding UTF8 |
            ConvertFrom-Json -AsHashtable -Depth 30
        $descriptorDigest = Get-AgentCanonicalDigest -InputObject $liveDescriptor
        $brokerScriptSha256 = [Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($brokerPath))).ToLowerInvariant()
        InModuleScope DevPilot.AgentHarness -Parameters @{
            DescriptorPath = $descriptorPath; DescriptorDigest = $descriptorDigest
            BrokerScriptSha256 = $brokerScriptSha256; BrokerPath = $brokerPath
        } {
            param($DescriptorPath, $DescriptorDigest, $BrokerScriptSha256, $BrokerPath)
            Mock Get-AgentImmediateParentProcessId { 999999 }
            Mock Get-Process { [Diagnostics.Process]::GetCurrentProcess() } -ParameterFilter { $Id -eq 999999 }
            Mock Get-AgentProcessStartIdentity { 'utc:123456789' }
            Mock Get-AgentProcessArgv { @{
                ExecutablePath = 'pwsh'
                Arguments = @('-NoLogo', '-File', $BrokerPath, '-DescriptorPath', $DescriptorPath)
            } }
            $manifest = @{
                role = 'reviewer'; brokerProcessId = 999999; brokerProcessStartIdentity = 'utc:123456789'
                brokerDescriptorPath = $DescriptorPath; brokerDescriptorDigest = $DescriptorDigest
                brokerScriptSha256 = $BrokerScriptSha256
            }
            { Assert-AgentBrokerProcessAnchor -Manifest $manifest } | Should -Not -Throw
        }
    }

    It 'Assert-AgentBrokerProcessAnchor rejects a wrong parent pid, a stale (PID-reuse) start identity, and a parent not running the pinned broker script' {
        $repositoryRoot = (Resolve-Path "$PSScriptRoot\..").Path
        $suiteRoot = Join-Path $TestDrive 'anchor-negative'
        $stateRoot = Resolve-AgentTrustedRoot -Path (Join-Path $suiteRoot 'watch') -Kind watch-state `
            -RepositoryRoot $repositoryRoot -Create
        $descriptorPath = Join-Path $stateRoot 'broker.descriptor.v1.json'
        @{ schemaVersion = 1; ownerProcessId = $PID; roles = @{ reviewer = @{ scriptPath = $reviewerPath } } } |
            ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $descriptorPath -Encoding utf8NoBOM
        if (-not $IsWindows) {
            [IO.File]::SetUnixFileMode($descriptorPath, [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite)
        }
        $liveDescriptor = Get-Content -LiteralPath $descriptorPath -Raw -Encoding UTF8 |
            ConvertFrom-Json -AsHashtable -Depth 30
        $descriptorDigest = Get-AgentCanonicalDigest -InputObject $liveDescriptor
        $brokerScriptSha256 = [Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($brokerPath))).ToLowerInvariant()
        InModuleScope DevPilot.AgentHarness -Parameters @{
            DescriptorPath = $descriptorPath; DescriptorDigest = $descriptorDigest
            BrokerScriptSha256 = $brokerScriptSha256; BrokerPath = $brokerPath
        } {
            param($DescriptorPath, $DescriptorDigest, $BrokerScriptSha256, $BrokerPath)
            $baseManifest = {
                @{
                    role = 'reviewer'; brokerProcessId = 999999; brokerProcessStartIdentity = 'utc:123456789'
                    brokerDescriptorPath = $DescriptorPath; brokerDescriptorDigest = $DescriptorDigest
                    brokerScriptSha256 = $BrokerScriptSha256
                }
            }

            Mock Get-AgentImmediateParentProcessId { 111111 }
            Mock Get-Process { [Diagnostics.Process]::GetCurrentProcess() } -ParameterFilter { $Id -eq 111111 }
            Mock Get-AgentProcessStartIdentity { 'utc:123456789' }
            Mock Get-AgentProcessArgv { @{ ExecutablePath = 'pwsh'; Arguments = @('-File', $BrokerPath, '-DescriptorPath', $DescriptorPath) } }
            { Assert-AgentBrokerProcessAnchor -Manifest (& $baseManifest) } |
                Should -Throw '*not directly spawned by the broker process*'

            Mock Get-AgentImmediateParentProcessId { 999999 }
            Mock Get-Process { [Diagnostics.Process]::GetCurrentProcess() } -ParameterFilter { $Id -eq 999999 }
            Mock Get-AgentProcessStartIdentity { 'utc:DIFFERENT' }
            Mock Get-AgentProcessArgv { @{ ExecutablePath = 'pwsh'; Arguments = @('-File', $BrokerPath, '-DescriptorPath', $DescriptorPath) } }
            { Assert-AgentBrokerProcessAnchor -Manifest (& $baseManifest) } |
                Should -Throw '*possible PID reuse*'

            Mock Get-AgentProcessStartIdentity { 'utc:123456789' }
            Mock Get-AgentProcessArgv { @{ ExecutablePath = 'pwsh'; Arguments = @('-NoProfile', '-Command', 'Start-Sleep -Seconds 30') } }
            { Assert-AgentBrokerProcessAnchor -Manifest (& $baseManifest) } |
                Should -Throw '*not running the pinned broker script*'
        }
    }

     It 'Assert-AgentBrokerProcessAnchor rejects a substring-spoofed command line, a duplicate -File, a wrong -File target with the trusted path only as later inert data, and a manifest descriptor path that does not match the verified parent argv' {
         # issue #105 PR5 parent-anchor-spoof fix: the prior implementation used
         # $liveParentCommandLine.IndexOf($expectedBrokerScript) -- a plain substring search. Every
         # case below has the trusted broker script's full path present as literal TEXT in the
         # command line, but never as the thing actually executed by -File in its real argument
         # position; a substring search alone would have wrongly accepted every one of them. Only
         # Get-AgentProcessArgv + Assert-AgentBrokerCommandLineShape's exact positional/allowlist
         # validation tells them apart from a genuine invocation.
         $repositoryRoot = (Resolve-Path "$PSScriptRoot\..").Path
         $suiteRoot = Join-Path $TestDrive 'anchor-argv-spoof'
         $stateRoot = Resolve-AgentTrustedRoot -Path (Join-Path $suiteRoot 'watch') -Kind watch-state `
             -RepositoryRoot $repositoryRoot -Create
         $descriptorPath = Join-Path $stateRoot 'broker.descriptor.v1.json'
         @{ schemaVersion = 1; ownerProcessId = $PID; roles = @{ reviewer = @{ scriptPath = $reviewerPath } } } |
             ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $descriptorPath -Encoding utf8NoBOM
         if (-not $IsWindows) {
             [IO.File]::SetUnixFileMode($descriptorPath, [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite)
         }
         $liveDescriptor = Get-Content -LiteralPath $descriptorPath -Raw -Encoding UTF8 |
             ConvertFrom-Json -AsHashtable -Depth 30
         $descriptorDigest = Get-AgentCanonicalDigest -InputObject $liveDescriptor
         $brokerScriptSha256 = [Convert]::ToHexString(
             [Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($brokerPath))).ToLowerInvariant()
         $decoyScriptPath = Join-Path $suiteRoot 'decoy.ps1'
         Set-Content -LiteralPath $decoyScriptPath -Value '# decoy, never actually the broker'
         InModuleScope DevPilot.AgentHarness -Parameters @{
             DescriptorPath = $descriptorPath; DescriptorDigest = $descriptorDigest
             BrokerScriptSha256 = $brokerScriptSha256; BrokerPath = $brokerPath; DecoyScriptPath = $decoyScriptPath
             SuiteRoot = $suiteRoot
         } {
             param($DescriptorPath, $DescriptorDigest, $BrokerScriptSha256, $BrokerPath, $DecoyScriptPath, $SuiteRoot)
             $baseManifest = {
                 @{
                     role = 'reviewer'; brokerProcessId = 999999; brokerProcessStartIdentity = 'utc:123456789'
                     brokerDescriptorPath = $DescriptorPath; brokerDescriptorDigest = $DescriptorDigest
                     brokerScriptSha256 = $BrokerScriptSha256
                 }
             }
             Mock Get-AgentImmediateParentProcessId { 999999 }
             Mock Get-Process { [Diagnostics.Process]::GetCurrentProcess() } -ParameterFilter { $Id -eq 999999 }
             Mock Get-AgentProcessStartIdentity { 'utc:123456789' }

             # (1) launcher uses `-Command` (real code execution) and appends the trusted broker
             # path as a second, inert, never-executed argument -- a plain substring search over
             # the raw command line would find the trusted path and wrongly accept this.
             Mock Get-AgentProcessArgv { @{
                 ExecutablePath = 'pwsh'
                 Arguments = @('-NoProfile', '-Command', 'Start-Sleep -Seconds 30', $BrokerPath)
             } }
             { Assert-AgentBrokerProcessAnchor -Manifest (& $baseManifest) } |
                 Should -Throw '*not running the pinned broker script*'

             # (2) a wrong -File target (a decoy script), with the real trusted broker path only
             # ever appearing later as inert -DescriptorPath data.
             Mock Get-AgentProcessArgv { @{
                 ExecutablePath = 'pwsh'
                 Arguments = @('-NoLogo', '-File', $DecoyScriptPath, '-DescriptorPath', $BrokerPath)
             } }
             { Assert-AgentBrokerProcessAnchor -Manifest (& $baseManifest) } |
                 Should -Throw '*not running the pinned broker script*'

             # (3) duplicate -File: the trusted script named once for real, then a second -File
             # reasserting it (or anything else) -- exactly one -File is ever accepted.
             Mock Get-AgentProcessArgv { @{
                 ExecutablePath = 'pwsh'
                 Arguments = @('-File', $BrokerPath, '-File', $BrokerPath, '-DescriptorPath', $DescriptorPath)
             } }
             { Assert-AgentBrokerProcessAnchor -Manifest (& $baseManifest) } |
                 Should -Throw '*not running the pinned broker script*'

             # (4) a genuinely, structurally valid broker invocation -- but the manifest's claimed
             # brokerDescriptorPath does not match what that verified parent's own command line
             # actually says its -DescriptorPath is. The manifest is no longer an independent
             # authority on the descriptor path: this must be rejected even though every other
             # claim (PID, start identity, script hash, digest) is otherwise consistent.
             $forgedDescriptorPath = Join-Path $SuiteRoot 'attacker-owned-descriptor.json'
             Mock Get-AgentProcessArgv { @{
                 ExecutablePath = 'pwsh'
                 Arguments = @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $BrokerPath, '-DescriptorPath', $forgedDescriptorPath)
             } }
             { Assert-AgentBrokerProcessAnchor -Manifest (& $baseManifest) } |
                 Should -Throw '*descriptor path does not match the verified broker process command line*'

             # Valid actual broker invocation shape passes structurally (reaches descriptor
             # resolution/digest comparison, which succeeds since $DescriptorPath is real).
             Mock Get-AgentProcessArgv { @{
                 ExecutablePath = 'pwsh'
                 Arguments = @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $BrokerPath, '-DescriptorPath', $DescriptorPath)
             } }
             { Assert-AgentBrokerProcessAnchor -Manifest (& $baseManifest) } | Should -Not -Throw
         }
     }

     It 'ConvertFrom-AgentWindowsCommandLineArgv tokenizes quoted paths with spaces, escaped quotes, and backslash runs exactly like CommandLineToArgvW' {
         InModuleScope DevPilot.AgentHarness {
             (ConvertFrom-AgentWindowsCommandLineArgv -CommandLine 'pwsh -NoLogo -File "C:\Program Files\script.ps1" -DescriptorPath "C:\a b\d.json"') |
                 Should -Be @('pwsh', '-NoLogo', '-File', 'C:\Program Files\script.ps1', '-DescriptorPath', 'C:\a b\d.json')
             # odd backslash count before a quote: the quote is escaped (literal) and does not toggle quoting
             (ConvertFrom-AgentWindowsCommandLineArgv -CommandLine 'prog a\\\"b c') | Should -Be @('prog', 'a\"b', 'c')
             # even backslash count before a quote: backslashes halve, quote toggles/delimits normally
             (ConvertFrom-AgentWindowsCommandLineArgv -CommandLine 'prog a\\\\"b c" d') | Should -Be @('prog', 'a\\b c', 'd')
             # doubled quote inside an already-quoted run collapses to one literal quote
             (ConvertFrom-AgentWindowsCommandLineArgv -CommandLine 'prog "a""b" c') | Should -Be @('prog', 'a"b', 'c')
             (ConvertFrom-AgentWindowsCommandLineArgv -CommandLine '') | Should -BeNullOrEmpty
         }
     }

     It 'Get-AgentProcessArgv identifies a real spawned process''s executable path and argument vector, matching the exact shape a real broker invocation uses' {
         $suiteRoot = Join-Path $TestDrive 'argv-integration'
         New-Item -ItemType Directory -Path $suiteRoot -Force | Out-Null
         $descriptorStandIn = Join-Path $suiteRoot 'descriptor.json'
         $pwshPath = Resolve-AgentPwshPath
         $stdOut = Join-Path $suiteRoot 'child.stdout.log'
         $stdErr = Join-Path $suiteRoot 'child.stderr.log'
         $child = New-AgentRedirectedProcess -FilePath $pwshPath -ArgumentList @(
             '-NoLogo', '-NoProfile', '-NonInteractive', '-File', $brokerPath, '-DescriptorPath', $descriptorStandIn
         ) -StandardOutputPath $stdOut -StandardErrorPath $stdErr
         try {
             Start-Sleep -Milliseconds 500
             $invocation = Get-AgentProcessArgv -ProcessId $child.Process.Id
             $invocation.ExecutablePath | Should -Match ([regex]::Escape('pwsh'))
             $resolvedDescriptor = Assert-AgentBrokerCommandLineShape -ExecutablePath $invocation.ExecutablePath `
                 -Arguments $invocation.Arguments -ExpectedBrokerScript $brokerPath
             $resolvedDescriptor | Should -Be ([IO.Path]::GetFullPath($descriptorStandIn))
         }
         finally {
             if (-not $child.Process.HasExited) { Stop-ProcessTree $child.Process; [void]$child.Process.WaitForExit(5000) }
         }
     }

    It 'Start-ReviewerAgent.ps1 rejects a same-user forger who truthfully reports their own real PID, start time, descriptor, and broker script hash' {
        # The strongest adversarial case: every claim in the manifest below is
        # TRUE about the test process itself (it really is the reviewer child's
        # immediate OS parent; its own start identity really is what it claims;
        # the descriptor and its digest, and the broker script hash, are all
        # real, valid, unmodified values). The one thing that cannot be true is
        # that this test process's own command line names the pinned broker
        # script -- it is the Pester test runner, not the broker -- so this
        # must still fail, proving the anchor defeats a forger who reports the
        # honest truth about everything except which script actually launched
        # them.
        $repositoryRoot = (Resolve-Path "$PSScriptRoot\..").Path
        $suiteRoot = Join-Path $TestDrive 'anchor-adversarial'
        $stateRoot = Resolve-AgentTrustedRoot -Path (Join-Path $suiteRoot 'watch') -Kind watch-state `
            -RepositoryRoot $repositoryRoot -Create
        $descriptorPath = Join-Path $stateRoot 'broker.descriptor.v1.json'
        @{ schemaVersion = 1; ownerProcessId = $PID; roles = @{ reviewer = @{ scriptPath = $reviewerPath } } } |
            ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $descriptorPath -Encoding utf8NoBOM
        if (-not $IsWindows) {
            [IO.File]::SetUnixFileMode($descriptorPath, [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite)
        }
        [void](Assert-AgentTrustedFile -Path $descriptorPath -AllowedRoot $stateRoot -ExpectedPath $descriptorPath -Private)
        $liveDescriptor = Get-Content -LiteralPath $descriptorPath -Raw -Encoding UTF8 |
            ConvertFrom-Json -AsHashtable -Depth 30
        $trueDescriptorDigest = Get-AgentCanonicalDigest -InputObject $liveDescriptor
        $trueBrokerScriptSha256 = [Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($brokerPath))).ToLowerInvariant()
        $manifestPath = Join-Path $suiteRoot 'dispatch-manifest.json'
        @{
            role = 'reviewer'; brokerProcessId = $PID
            brokerProcessStartIdentity = (Get-AgentProcessStartIdentity -Process ([Diagnostics.Process]::GetCurrentProcess()))
            brokerDescriptorPath = $descriptorPath; brokerDescriptorDigest = $trueDescriptorDigest
            brokerScriptSha256 = $trueBrokerScriptSha256
        } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $manifestPath -Encoding utf8NoBOM

        # Fake, attacker-minted attestation channel: a real anonymous pipe (with
        # arbitrary bytes) and a real but unrelated named startup pipe -- neither
        # should even be reached before the anchor check throws.
        $fakeAttestationPipe = [IO.Pipes.AnonymousPipeServerStream]::new(
            [IO.Pipes.PipeDirection]::Out, [IO.HandleInheritability]::Inheritable)
        $fakeNamedPipe = [IO.Pipes.NamedPipeServerStream]::new((New-AgentPipeName),
            [IO.Pipes.PipeDirection]::InOut, 1, [IO.Pipes.PipeTransmissionMode]::Byte,
            [IO.Pipes.PipeOptions]::Asynchronous -bor [IO.Pipes.PipeOptions]::CurrentUserOnly)
        $stdOutPath = Join-Path $suiteRoot 'reviewer.stdout.log'
        $stdErrPath = Join-Path $suiteRoot 'reviewer.stderr.log'
        try {
            $fakeAttestationPipe.Write([byte[]](1..16), 0, 16)
            $fakeAttestationPipe.Flush()
            $started = [DateTime]::UtcNow
            $reviewer = New-AgentRedirectedProcess -FilePath (Resolve-AgentPwshPath) -ArgumentList @(
                '-NoLogo', '-NoProfile', '-NonInteractive', '-File', $reviewerPath,
                '-ManualDispatchManifest', $manifestPath
            ) -StandardOutputPath $stdOutPath -StandardErrorPath $stdErrPath `
                -AdditionalEnvironmentVariables @{ DEVPILOT_BROKER_ATTESTATION_HANDLE = $fakeAttestationPipe.GetClientHandleAsString() }
            $fakeAttestationPipe.DisposeLocalCopyOfClientHandle()
            try {
                $exited = $reviewer.Process.WaitForExit(15000)
                $elapsed = ([DateTime]::UtcNow - $started).TotalSeconds
                $completion = Complete-AgentRedirectedProcess $reviewer
                $exited | Should -BeTrue -Because "a rejected launch must fail fast, not hang; stderr: $($completion.SafeErrorTail)"
                $reviewer.Process.ExitCode | Should -Not -Be 0
                $completion.SafeErrorTail | Should -Match '\[broker-attestation-invalid\]'
                # Before any provider/network setup: those later stages would
                # need -Organization/-RepositoryName and would emit very
                # different failures (missing PR provider config, etc.), never
                # this message, and would not fail in well under the interval
                # this early guard is designed to short-circuit before.
                $elapsed | Should -BeLessThan 10
            }
            finally {
                if (-not $reviewer.Process.HasExited) { Stop-ProcessTree $reviewer.Process; [void]$reviewer.Process.WaitForExit(5000) }
            }
        }
        finally {
            $fakeAttestationPipe.Dispose()
            $fakeNamedPipe.Dispose()
        }
    }

    It 'documents the broker-issuer anchor anti-mistake boundary: an ordinary caller, not a privileged same-user attacker' {
        $source = Get-Content -LiteralPath (Resolve-Path "$PSScriptRoot\..\src\DevPilot.AgentHarness\DevPilot.AgentHarness.psm1") -Raw
        $anchorBody = [regex]::Match($source, '(?s)function Assert-AgentBrokerProcessAnchor \{.*?ANTI-MISTAKE BOUNDARY.*?#>').Value
        $anchorBody | Should -Not -BeNullOrEmpty
        $anchorBody | Should -Match 'NOT a defense against a deliberate'
        $anchorBody | Should -Match 'out of scope'
    }
}
