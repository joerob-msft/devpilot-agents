BeforeAll {
    Import-Module "$PSScriptRoot\..\src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1" -Force
    $script:brokerPath = (Resolve-Path "$PSScriptRoot\..\tools\Invoke-DevPilotAgentDispatch.ps1").Path
    $script:watchPath = (Resolve-Path "$PSScriptRoot\..\tools\Watch-DevPilotAgents.ps1").Path
    $script:reviewerPath = (Resolve-Path "$PSScriptRoot\..\src\Agents\reviewer\Start-ReviewerAgent.ps1").Path
    $script:handlerPath = (Resolve-Path "$PSScriptRoot\..\src\Agents\review-handler\Start-ReviewHandlerAgent.ps1").Path
    $script:guardianPath = (Resolve-Path "$PSScriptRoot\..\tools\Invoke-DevPilotPromptGuardian.ps1").Path
}

Describe 'dispatch protocol primitives' {
    It 'emits deterministic canonical JSON and separate digests' {
        ConvertTo-AgentCanonicalJson ([ordered]@{ z = 2; a = @($true, $null, 'x') }) |
            Should -BeExactly '{"a":[true,null,"x"],"z":2}'
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
        $source | Should -Match "mandatoryDenies = @\('EnableApprovalVote'\)"
        $source | Should -Not -Match "manualRoles\.reviewer.+EnableApprovalVote"
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
            }
            capabilityPolicyDigest = 'invalid'
        } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $manifest -Encoding utf8NoBOM
        {
            Enter-AgentManualDispatchStartup -ManifestPath $manifest -RepositoryIdentity @{
                key = 'v1:github:1'; verified = $true
            } -DurableContext @{} -LeaseRoot $TestDrive -Role reviewer `
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
            } -DurableContext @{} -LeaseRoot $TestDrive -Role reviewer `
                -EventLogPath (Join-Path $TestDrive 'event.jsonl') `
                -BoundCapabilities @{
                    EnableFindingComments = $false
                    EnableApprovalVote = $false
                }
        } | Should -Throw '*policy is malformed or inconsistent*'
        {
            Enter-AgentManualDispatchStartup -ManifestPath $manifest -RepositoryIdentity @{
                key = 'v1:github:1'; verified = $true
            } -DurableContext @{} -LeaseRoot $TestDrive -Role reviewer `
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
        $signalFunction | Should -Match 'StartTime\.ToUniversalTime\(\)\.Ticks'
        $signalFunction | Should -Match '\$Signal -ne 0'
        $source | Should -Match 'Test-GuardianLeaderLive'
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
        $invalid.StdErr | Should -Match 'ReviewerPullRequestId must be greater than zero'

        $mismatched = Invoke-TimedProcess -FilePath (Resolve-AgentPwshPath) -ArgumentList @(
            '-NoProfile', '-NonInteractive', '-File', $watchPath,
            '-Agent', 'ReviewHandler', '-ReviewerPullRequestId', '104') `
            -CaptureStdOut -CaptureStdErr -TimeoutSeconds 20
        $mismatched.ExitCode | Should -Not -Be 0
        $mismatched.StdErr | Should -Match 'ReviewerPullRequestId requires -Agent Reviewer or -Agent Both'
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
            $process.StandardInput.WriteLine((ConvertTo-AgentCanonicalJson @{
                        schemaVersion = 1; requestId = $shutdownId; operation = 'shutdown'
                    }))
            $process.StandardInput.Close()
            $process.WaitForExit(15000) | Should -BeTrue
            $responses = @($process.StandardOutput.ReadToEnd() -split "`r?`n" |
                Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json -AsHashtable })
            $stderr = $process.StandardError.ReadToEnd()
            $process.ExitCode | Should -Be 0 -Because $stderr
            $responses.Count | Should -Be 2
            $responses[0].requestId | Should -BeExactly $describeId
            $responses[0].operation | Should -BeExactly 'rejected'
            $responses[0].code | Should -BeExactly 'role-not-allowed'
            $responses[1].requestId | Should -BeExactly $shutdownId
            $responses[1].operation | Should -BeExactly 'shutdown-complete'
            Test-Path (Join-Path $stateRoot 'manual-dispatch') | Should -BeFalse
        }
        finally {
            if (-not $process.HasExited) { $process.Kill($true); [void]$process.WaitForExit(5000) }
            $process.Dispose()
        }
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
            -RuntimeRoot $runtimeRoot -BrokerProcessId $deadPid -BrokerStartTimeUtcTicks 1 `
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
                '-BrokerProcessId', [string]$broker.Id, '-BrokerStartTimeUtcTicks',
                [string]$broker.StartTime.ToUniversalTime().Ticks, '-Token', $token,
                '-DeadlineSeconds', '30') `
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
                childLeaderStartTimeUtcTicks = $child.Process.StartTime.ToUniversalTime().Ticks
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
            $childExited | Should -BeTrue -Because (
                "the guardian must terminate the accepted child group after the broker dies" +
                $(if ($childKillDiagnostics) { "; guardian stderr: $($childKillDiagnostics.SafeErrorTail)" }))
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
            childLeaderStartTimeUtcTicks = 1
            paths = @('operator-context.txt')
        } | ConvertTo-Json -Compress | Set-Content `
            -LiteralPath (Join-Path $runtimeRoot "guardian-$token.json") -Encoding utf8NoBOM
        [IO.File]::SetUnixFileMode((Join-Path $runtimeRoot "guardian-$token.json"),
            [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite)
        try {
            $result = Invoke-TimedProcess -FilePath (Resolve-AgentPwshPath) -ArgumentList @(
                '-NoLogo', '-NoProfile', '-NonInteractive', '-File', $guardianPath,
                '-RuntimeRoot', $runtimeRoot, '-BrokerProcessId', '2147483647',
                '-BrokerStartTimeUtcTicks', '1',
                '-Token', $token, '-DeadlineSeconds', '2') -CaptureStdOut -CaptureStdErr -TimeoutSeconds 2
            $result.TimedOut | Should -BeTrue
            $leader.Process.HasExited | Should -BeFalse
        }
        finally {
            if (-not $leader.Process.HasExited) { Stop-ProcessTree $leader.Process }
            [void](Complete-AgentRedirectedProcess $leader)
        }
    }
}
