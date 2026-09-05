BeforeAll {
    Import-Module "$PSScriptRoot\..\src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1" -Force
    $script:repoRoot = (Resolve-Path "$PSScriptRoot\..").Path
    $script:toolsRoot = Join-Path $script:repoRoot 'tools'
    $script:watchPath = Join-Path $script:toolsRoot 'Watch-DevPilotAgents.ps1'
    $script:brokerPath = Join-Path $script:toolsRoot 'Invoke-DevPilotAgentDispatch.ps1'
    $script:reviewerDescriptor = Get-AgentHarnessCapabilityDescriptor -Role reviewer
    $script:handlerDescriptor = Get-AgentHarnessCapabilityDescriptor -Role review-handler

    # Every test below runs the REAL launcher, but against a freshly hardened TestDrive copy of the
    # toolkit rather than the live checkout: this repository's own working-tree ACL can grant write
    # access to a non-owner principal on a shared/mapped-drive checkout, which the launcher's own
    # trust preflight correctly refuses. Only the dashboard launcher and the two agent entry points
    # are replaced (by recorders); the launcher, the wrappers, and the harness module are the real,
    # unmodified files.
    function New-HardenedDirectory {
        param([Parameter(Mandatory)][string]$Path)
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
        if ($IsWindows) {
            $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
            $acl = [Security.AccessControl.DirectorySecurity]::new()
            $acl.SetOwner($identity.User)
            $acl.SetAccessRuleProtection($true, $false)
            $inheritance = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
                [Security.AccessControl.InheritanceFlags]::ObjectInherit
            $systemSid = [Security.Principal.SecurityIdentifier]::new(
                [Security.Principal.WellKnownSidType]::LocalSystemSid, $null)
            foreach ($sid in @($identity.User, $systemSid)) {
                $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
                        $sid, [Security.AccessControl.FileSystemRights]::FullControl, $inheritance,
                        [Security.AccessControl.PropagationFlags]::None,
                        [Security.AccessControl.AccessControlType]::Allow))
            }
            Set-Acl -LiteralPath $Path -AclObject $acl
        }
        else {
            [IO.File]::SetUnixFileMode($Path,
                [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite -bor [IO.UnixFileMode]::UserExecute)
        }
        return [IO.Path]::GetFullPath($Path)
    }

    $script:dashboardRecorder = @'
param(
    [Parameter(Position = 0)][string[]]$StateDir = @(),
    [string[]]$EventLogPath = @(),
    [string]$BrokerDescriptorPath,
    [string]$LaunchMode = 'observe',
    [switch]$ValidateOnly
)
$record = [ordered]@{
    validateOnly = [bool]$ValidateOnly
    launchMode = $LaunchMode
    stateDir = @($StateDir)
    brokerDescriptorPath = [string]$BrokerDescriptorPath
    descriptor = $(if ($BrokerDescriptorPath -and (Test-Path -LiteralPath $BrokerDescriptorPath -PathType Leaf)) {
        Get-Content -LiteralPath $BrokerDescriptorPath -Raw
    } else { '' })
}
Add-Content -LiteralPath $env:DEVPILOT_TEST_DASHBOARD_LOG -Value ($record | ConvertTo-Json -Depth 10 -Compress)
$callNumber = if (Test-Path -LiteralPath $env:DEVPILOT_TEST_DASHBOARD_LOG -PathType Leaf) {
    @(Get-Content -LiteralPath $env:DEVPILOT_TEST_DASHBOARD_LOG).Count
} else { 1 }
$failCall = if ($env:DEVPILOT_TEST_DASHBOARD_FAIL_CALL) { [int]$env:DEVPILOT_TEST_DASHBOARD_FAIL_CALL } else { 0 }
exit $(if ($env:DEVPILOT_TEST_DASHBOARD_EXITCODE -and ($failCall -eq 0 -or $failCall -eq $callNumber)) {
    [int]$env:DEVPILOT_TEST_DASHBOARD_EXITCODE
} else { 0 })
'@

    $script:agentRecorder = @'
$role = if ($PSCommandPath -match 'ReviewHandler') { 'review-handler' } else { 'reviewer' }
$path = Join-Path $env:DEVPILOT_TEST_ARGV_DIR "$role.argv.json"
[IO.File]::WriteAllText($path, (ConvertTo-Json @($args) -Depth 5), [Text.UTF8Encoding]::new($false))
exit 0
'@

    function New-GoldenContext {
        $root = New-HardenedDirectory (Join-Path $TestDrive ([Guid]::NewGuid().ToString('N')))
        New-Item -ItemType Directory -Path (Join-Path $root 'tools') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $root 'src\Agents\reviewer') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $root 'src\Agents\review-handler') -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $script:repoRoot 'src\DevPilot.AgentHarness') `
            -Destination (Join-Path $root 'src') -Recurse -Force
        foreach ($name in @('Watch-DevPilotAgents.ps1', 'Watch-DevPilotReviewer.ps1',
                'Watch-DevPilotReviewHandler.ps1', 'Invoke-DevPilotAgentDispatch.ps1')) {
            Copy-Item -LiteralPath (Join-Path $script:toolsRoot $name) `
                -Destination (Join-Path $root "tools\$name") -Force
        }
        [IO.File]::WriteAllText((Join-Path $root 'tools\Start-DevPilotDashboard.ps1'),
            $script:dashboardRecorder, [Text.UTF8Encoding]::new($false))
        foreach ($relative in @('src\Agents\reviewer\Start-ReviewerAgent.ps1',
                'src\Agents\review-handler\Start-ReviewHandlerAgent.ps1')) {
            [IO.File]::WriteAllText((Join-Path $root $relative), $script:agentRecorder, [Text.UTF8Encoding]::new($false))
        }
        $configRoot = New-HardenedDirectory (Join-Path $root 'agent-config')
        $reviewerConfig = Join-Path $configRoot 'reviewer.config.json'
        $handlerConfig = Join-Path $configRoot 'review-handler.config.json'
        foreach ($configPath in @($reviewerConfig, $handlerConfig)) {
            [IO.File]::WriteAllText($configPath, '{}', [Text.UTF8Encoding]::new($false))
        }
        $support = New-HardenedDirectory (Join-Path $TestDrive ([Guid]::NewGuid().ToString('N')))
        $appData = New-HardenedDirectory (Join-Path $support 'appdata')
        $argvDir = New-HardenedDirectory (Join-Path $support 'argv')
        return @{
            Root = $root
            AppData = $appData
            ArgvDir = $argvDir
            DashboardLog = (Join-Path $support 'dashboard.jsonl')
            WatchRoot = (Join-Path (Join-Path $appData 'DevPilot') 'watch')
            ReviewerConfig = $reviewerConfig
            ReviewHandlerConfig = $handlerConfig
        }
    }

    function Invoke-GoldenLaunch {
        param(
            [Parameter(Mandatory)][hashtable]$Context,
            [string[]]$Arguments = @(),
            [string]$Script = 'Watch-DevPilotAgents.ps1',
            [int]$DashboardExitCode = 0,
            [int]$DashboardFailCall = 0,
            [int]$TimeoutSeconds = 120
        )
        $saved = @{
            Log = $env:DEVPILOT_TEST_DASHBOARD_LOG
            Argv = $env:DEVPILOT_TEST_ARGV_DIR
            Exit = $env:DEVPILOT_TEST_DASHBOARD_EXITCODE
            FailCall = $env:DEVPILOT_TEST_DASHBOARD_FAIL_CALL
            LocalAppData = $env:LOCALAPPDATA
            XdgStateHome = $env:XDG_STATE_HOME
        }
        try {
            $env:DEVPILOT_TEST_DASHBOARD_LOG = $Context.DashboardLog
            $env:DEVPILOT_TEST_ARGV_DIR = $Context.ArgvDir
            $env:DEVPILOT_TEST_DASHBOARD_EXITCODE = [string]$DashboardExitCode
            $env:DEVPILOT_TEST_DASHBOARD_FAIL_CALL = [string]$DashboardFailCall
            # Redirects Get-AgentDefaultWatchStateRoot / DurableStateRoot / LeaseRoot into the
            # per-test sandbox, so the launcher's own default roots (and its cross-launch history
            # scan) are exercised without ever touching the operator's real state.
            if ($IsWindows) { $env:LOCALAPPDATA = $Context.AppData } else { $env:XDG_STATE_HOME = $Context.AppData }
            return Invoke-TimedProcess -FilePath (Resolve-AgentPwshPath) -ArgumentList (@(
                    '-NoLogo', '-NoProfile', '-NonInteractive', '-File',
                    (Join-Path $Context.Root "tools\$Script")) + @($Arguments)) `
                -WorkingDirectory $Context.Root -CaptureStdOut -CaptureStdErr -TimeoutSeconds $TimeoutSeconds
        }
        finally {
            $env:DEVPILOT_TEST_DASHBOARD_LOG = $saved.Log
            $env:DEVPILOT_TEST_ARGV_DIR = $saved.Argv
            $env:DEVPILOT_TEST_DASHBOARD_EXITCODE = $saved.Exit
            $env:DEVPILOT_TEST_DASHBOARD_FAIL_CALL = $saved.FailCall
            $env:LOCALAPPDATA = $saved.LocalAppData
            $env:XDG_STATE_HOME = $saved.XdgStateHome
        }
    }

    function Get-DashboardRecord {
        param([Parameter(Mandatory)][hashtable]$Context)
        if (-not (Test-Path -LiteralPath $Context.DashboardLog -PathType Leaf)) { return , @() }
        # Comma-wrapped so a single recorded invocation stays an ARRAY of one record instead of
        # being unrolled into the record hashtable itself (whose .Count would be its key count).
        return , @(Get-Content -LiteralPath $Context.DashboardLog | Where-Object { $_ } |
            ForEach-Object { $_ | ConvertFrom-Json -AsHashtable })
    }

    function Get-AgentArgv {
        param([Parameter(Mandatory)][hashtable]$Context, [Parameter(Mandatory)][string]$Role)
        $path = Join-Path $Context.ArgvDir "$Role.argv.json"
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
        return , @(Get-Content -LiteralPath $path -Raw | ConvertFrom-Json)
    }

    function Get-BaseLaunchArgument {
        param([Parameter(Mandatory)][hashtable]$Context)
        return @('-OperatorAlias', 'golden-test',
            '-ReviewerConfigFile', $Context.ReviewerConfig,
            '-ReviewHandlerConfigFile', $Context.ReviewHandlerConfig)
    }

    function Get-FlattenedError {
        # PowerShell wraps a thrown message across several console lines (with an ANSI-coloured '|'
        # gutter), so assertions match against the flattened, single-line, unstyled form instead.
        param([AllowNull()][string]$Text)
        $plain = ([string]$Text) -replace '\x1b\[[0-9;]*[A-Za-z]', ''
        return ((($plain -replace '\r?\n\s*\|?\s*', ' ') -replace '\s+', ' '))
    }
}

Describe 'preview-only capability projection (issue #114)' {
    It 'locks every mutation-capable and delegable capability, and stays empty otherwise' {
        foreach ($role in @('reviewer', 'review-handler')) {
            $operational = Get-AgentHarnessCapabilityDescriptor -Role $role
            $preview = Get-AgentHarnessCapabilityDescriptor -Role $role -PreviewOnly
            $operational.absoluteDenies | Should -BeExactly @()
            $preview.absoluteDenies | Should -BeExactly (
                @(@($operational.allowedManualCapabilities) + @($operational.delegableDefaultOff) | Sort-Object -Unique))
            $preview.absoluteDenies | Should -Contain $operational.delegableDefaultOff
            # The preview projection narrows nothing else: the ceiling itself is unchanged, only
            # what may be granted from it.
            $preview.allowedManualCapabilities | Should -BeExactly $operational.allowedManualCapabilities
            $preview.delegableDefaultOff | Should -BeExactly $operational.delegableDefaultOff
        }
        (Get-AgentHarnessCapabilityDescriptor -Role reviewer -PreviewOnly).absoluteDenies |
            Should -BeExactly @('EnableApprovalVote', 'EnableFindingComments', 'EnableSummaryComment', 'EnableThreadReplies')
        (Get-AgentHarnessCapabilityDescriptor -Role review-handler -PreviewOnly).absoluteDenies |
            Should -BeExactly @('EnableAutoComplete', 'EnableBuddyRequeue', 'EnableCodeChanges', 'EnablePush',
                'EnableThreadReplies', 'LocalValidation', 'ResumeCodingSession')
    }

    It 'binds preview and observe dashboard labels to the broker descriptor authority' {
        $previewRoles = @{}
        foreach ($role in @('reviewer', 'review-handler')) {
            $previewRoles[$role] = @{
                capabilities = @()
                absoluteDenies = @((Get-AgentHarnessCapabilityDescriptor -Role $role -PreviewOnly).absoluteDenies)
            }
        }
        $previewDescriptor = @{ roles = $previewRoles }
        { Assert-AgentDashboardLaunchAuthority -LaunchMode preview -BrokerDescriptor $previewDescriptor } |
            Should -Not -Throw
        { Assert-AgentDashboardLaunchAuthority -LaunchMode operational -BrokerDescriptor @{
                roles = @{ reviewer = @{ capabilities = @('EnableThreadReplies'); absoluteDenies = @() } }
            } } | Should -Not -Throw
        { Assert-AgentDashboardLaunchAuthority -LaunchMode observe -BrokerDescriptor $previewDescriptor } |
            Should -Throw '*Observe mode cannot be combined with broker authority*'
        { Assert-AgentDashboardLaunchAuthority -LaunchMode preview -BrokerDescriptor @{
                roles = @{ reviewer = @{ capabilities = @('EnableThreadReplies'); absoluteDenies = @() } }
            } } | Should -Throw '*complete terminal absolute-deny ceiling*'
        { Assert-AgentDashboardLaunchAuthority -LaunchMode preview -BrokerDescriptor @{
                roles = @{ reviewer = @{
                        capabilities = @()
                        absoluteDenies = @('EnableApprovalVote')
                    } }
            } } | Should -Throw '*complete terminal absolute-deny ceiling*'
    }

    It 'reports trusted-root creation ownership without claiming an existing root' {
        $root = Join-Path $TestDrive ([Guid]::NewGuid().ToString('N'))
        $created = $false
        Resolve-AgentTrustedRoot -Path $root -Kind watch-state -RepositoryRoot $script:repoRoot `
            -Create -CreatedByCaller ([ref]$created) | Should -BeExactly ([IO.Path]::GetFullPath($root))
        $created | Should -BeTrue

        $created = $true
        Resolve-AgentTrustedRoot -Path $root -Kind watch-state -RepositoryRoot $script:repoRoot `
            -Create -CreatedByCaller ([ref]$created) | Should -BeExactly ([IO.Path]::GetFullPath($root))
        $created | Should -BeFalse
    }

    It 'removes absolutely denied capabilities from the partition and refuses to widen one' {
        $roleDescriptor = @{
            capabilities = @('EnableFindingComments', 'EnableThreadReplies')
            mandatoryDenies = @('EnableApprovalVote')
        }
        $unlocked = Resolve-AgentCapabilityPolicyPartition -RoleDescriptor $roleDescriptor -PersistedNarrowing @{}
        $unlocked.capabilities | Should -BeExactly @('EnableFindingComments', 'EnableThreadReplies')

        $locked = Resolve-AgentCapabilityPolicyPartition -RoleDescriptor $roleDescriptor -PersistedNarrowing @{} `
            -AbsoluteDenies @('EnableFindingComments', 'EnableApprovalVote')
        $locked.capabilities | Should -BeExactly @('EnableThreadReplies')
        $locked.mandatoryDenies | Should -BeExactly @('EnableApprovalVote', 'EnableFindingComments')

        { Resolve-AgentCapabilityPolicyPartition -RoleDescriptor $roleDescriptor -PersistedNarrowing @{} `
                -AbsoluteDenies @('EnableApprovalVote') -GrantCapability 'EnableApprovalVote' } |
            Should -Throw '*absolutely denied for this launch*'
        # Outside a preview launch the same grant is still perfectly valid: preview is the only
        # thing that makes the delegable capability non-delegable.
        (Resolve-AgentCapabilityPolicyPartition -RoleDescriptor $roleDescriptor -PersistedNarrowing @{} `
                -GrantCapability 'EnableApprovalVote').capabilities | Should -Contain 'EnableApprovalVote'
    }

    It 'enforces descriptor-supplied absolute denies on every broker path that could widen' {
        $source = Get-Content -LiteralPath $script:brokerPath -Raw
        # The launch's denies come from the descriptor the trusted launcher wrote, never from the
        # harness default (which cannot know how this launch was started).
        $source | Should -Match '\$absoluteDenies = @\(\$roleDescriptor\.absoluteDenies \| Sort-Object -Unique\)'
        $source | Should -Not -Match '\$absoluteDenies = @\(\$harnessRole\.absoluteDenies'
        $source | Should -Match 'function Assert-RoleCapabilityPolicy'

        $roleDescriptorBody = [regex]::Match($source, '(?s)function Get-RoleDescriptor \{.*?\n\}').Value
        $roleDescriptorBody | Should -Match 'Assert-RoleCapabilityPolicy'

        $candidateBody = [regex]::Match($source, '(?s)function Get-DraftWideningCandidate \{.*?\n\}').Value
        ([regex]::Matches($candidateBody, '-AbsoluteDenies')).Count | Should -Be 2

        $describeWideningBody = [regex]::Match($source, '(?s)function Invoke-DescribeWidening \{.*?\n\}').Value
        $describeWideningBody | Should -Match 'absoluteDenies\) -ccontains \$capability'
        $describeWideningBody | Should -Match 'absolutely denied for this launch'

        $narrowingEffectBody = [regex]::Match($source, '(?s)function Get-BrokerNarrowingEffect \{.*?\n\}').Value
        $narrowingEffectBody | Should -Match '-AbsoluteDenies \$AbsoluteDenies'

        $dispatchBody = [regex]::Match($source, '(?s)function Invoke-Dispatch \{.*?\n\}').Value
        $dispatchBody | Should -Match '\$dispatchAbsoluteDenies -ccontains \$_'
        $dispatchBody | Should -Match 'absolutely denies'

        # The delegable capability is only hidden from the dashboard when the launch itself locked
        # it; it stays offered (subject to the checked-in delegation policy) otherwise.
        $source | Should -Match '\$absoluteDenies -cnotcontains \$harnessRole\.delegableDefaultOff'
    }
}

Describe 'golden launch policy (issue #114)' {
    It 'launches both agents operationally, continuously, with manual writes and no vote or Teams' {
        $context = New-GoldenContext
        $result = Invoke-GoldenLaunch -Context $context -Arguments (@('-Golden') + (Get-BaseLaunchArgument -Context $context))
        $result.ExitCode | Should -Be 0 -Because $result.StdErr

        $reviewerArgv = Get-AgentArgv -Context $context -Role 'reviewer'
        $handlerArgv = Get-AgentArgv -Context $context -Role 'review-handler'
        $reviewerArgv | Should -Not -BeNullOrEmpty
        $handlerArgv | Should -Not -BeNullOrEmpty
        foreach ($capability in @($script:reviewerDescriptor.operationalTiers.base)) {
            $reviewerArgv | Should -Contain "-$capability"
        }
        foreach ($capability in @($script:handlerDescriptor.operationalTiers.base) +
            @($script:handlerDescriptor.operationalTiers.codeUpdate)) {
            $handlerArgv | Should -Contain "-$capability"
        }
        # Golden never turns on the delegable capability or notification delivery.
        $reviewerArgv | Should -Not -Contain "-$($script:reviewerDescriptor.delegableDefaultOff)"
        $handlerArgv | Should -Not -Contain "-$($script:handlerDescriptor.delegableDefaultOff)"
        foreach ($argv in @($reviewerArgv, $handlerArgv)) {
            $argv | Should -Not -Contain '-EnableTeamsNotifications'
            $argv | Should -Not -Contain '-Once'
            $argv | Should -Contain '-IntervalSeconds'
        }

        $records = Get-DashboardRecord -Context $context
        $records.Count | Should -Be 3
        $records[0].validateOnly | Should -BeTrue
        $records[0].descriptor | Should -BeExactly ''
        $records[1].validateOnly | Should -BeTrue
        $records[2].validateOnly | Should -BeFalse
        foreach ($record in $records) { $record.launchMode | Should -BeExactly 'operational' }

        $descriptor = $records[1].descriptor | ConvertFrom-Json -AsHashtable
        @($descriptor.roles.Keys | Sort-Object) | Should -BeExactly @('review-handler', 'reviewer')
        @($descriptor.roles.reviewer.capabilities | Sort-Object) |
            Should -BeExactly @($script:reviewerDescriptor.operationalTiers.base | Sort-Object)
        $descriptor.roles.reviewer.mandatoryDenies | Should -BeExactly @($script:reviewerDescriptor.delegableDefaultOff)
        $descriptor.roles.reviewer.absoluteDenies | Should -BeExactly @()
        @($descriptor.roles.'review-handler'.capabilities | Sort-Object) | Should -BeExactly (
            @(@($script:handlerDescriptor.operationalTiers.base) +
                @($script:handlerDescriptor.operationalTiers.codeUpdate) | Sort-Object))
        $descriptor.roles.'review-handler'.mandatoryDenies | Should -BeExactly @($script:handlerDescriptor.delegableDefaultOff)
        $descriptor.roles.'review-handler'.absoluteDenies | Should -BeExactly @()

        $result.StdOut | Should -Match 'Mode\s+: OPERATIONAL'
        $result.StdOut | Should -Match 'Operator\s+: golden-test'
        $result.StdOut | Should -Match 'Preview alternative'
    }

    It 'applies PreviewOnly as a terminal ceiling over every golden default' {
        $context = New-GoldenContext
        $result = Invoke-GoldenLaunch -Context $context `
            -Arguments (@('-Golden', '-PreviewOnly') + (Get-BaseLaunchArgument -Context $context))
        $result.ExitCode | Should -Be 0 -Because $result.StdErr

        $reviewerArgv = Get-AgentArgv -Context $context -Role 'reviewer'
        $handlerArgv = Get-AgentArgv -Context $context -Role 'review-handler'
        foreach ($capability in @($script:reviewerDescriptor.allowedManualCapabilities) +
            @($script:reviewerDescriptor.delegableDefaultOff)) {
            $reviewerArgv | Should -Not -Contain "-$capability"
        }
        foreach ($capability in @($script:handlerDescriptor.allowedManualCapabilities) +
            @($script:handlerDescriptor.delegableDefaultOff)) {
            $handlerArgv | Should -Not -Contain "-$capability"
        }
        foreach ($argv in @($reviewerArgv, $handlerArgv)) {
            $argv | Should -Not -Contain '-EnableTeamsNotifications'
            # PreviewOnly overrides golden's writes, never golden's continuity.
            $argv | Should -Contain '-IntervalSeconds'
            $argv | Should -Not -Contain '-Once'
        }

        $records = Get-DashboardRecord -Context $context
        foreach ($record in $records) { $record.launchMode | Should -BeExactly 'preview' }
        $descriptor = $records[1].descriptor | ConvertFrom-Json -AsHashtable
        foreach ($case in @(
                @{ Role = 'reviewer'; Descriptor = $script:reviewerDescriptor },
                @{ Role = 'review-handler'; Descriptor = $script:handlerDescriptor })) {
            $entry = $descriptor.roles[$case.Role]
            $expectedLock = @(@($case.Descriptor.allowedManualCapabilities) +
                @($case.Descriptor.delegableDefaultOff) | Sort-Object -Unique)
            $entry.capabilities | Should -BeExactly @()
            $entry.absoluteDenies | Should -BeExactly $expectedLock
            $entry.mandatoryDenies | Should -BeExactly $expectedLock
            $entry.absoluteDenies | Should -Contain $case.Descriptor.delegableDefaultOff
        }
        $result.StdOut | Should -Match 'Mode\s+: PREVIEW ONLY'
        $result.StdOut | Should -Match 'absolute, non-delegable'
    }

    It 'lets -Once override golden continuity and keeps a fixed pull request valid' {
        $context = New-GoldenContext
        $result = Invoke-GoldenLaunch -Context $context -Arguments (@('-Golden', '-Once',
                '-ReviewerPullRequestId', '104') + (Get-BaseLaunchArgument -Context $context))
        $result.ExitCode | Should -Be 0 -Because $result.StdErr
        $reviewerArgv = Get-AgentArgv -Context $context -Role 'reviewer'
        $reviewerArgv | Should -Contain '-Once'
        $reviewerArgv | Should -Not -Contain '-IntervalSeconds'
        $reviewerArgv | Should -Contain '-PullRequestId'
        $reviewerArgv | Should -Contain '104'
        (Get-DashboardRecord -Context $context)[0].launchMode | Should -BeExactly 'operational'
    }

    It 'keeps a bare launch a single preview cycle with no broker descriptor' {
        $context = New-GoldenContext
        $result = Invoke-GoldenLaunch -Context $context -Arguments (Get-BaseLaunchArgument -Context $context)
        $result.ExitCode | Should -Be 0 -Because $result.StdErr
        foreach ($role in @('reviewer', 'review-handler')) {
            $argv = Get-AgentArgv -Context $context -Role $role
            $argv | Should -Contain '-Once'
            $argv | Should -Not -Contain '-IntervalSeconds'
            $argv | Should -Not -Contain '-EnableTeamsNotifications'
            foreach ($capability in @($script:reviewerDescriptor.allowedManualCapabilities) +
                @($script:handlerDescriptor.allowedManualCapabilities)) {
                $argv | Should -Not -Contain "-$capability"
            }
        }
        $records = Get-DashboardRecord -Context $context
        foreach ($record in $records) {
            $record.launchMode | Should -BeExactly 'preview'
            $record.brokerDescriptorPath | Should -BeExactly ''
        }
    }

    It 'labels a manual write-capable launch operational even when automatic agents remain preview-only' {
        $context = New-GoldenContext
        $result = Invoke-GoldenLaunch -Context $context -Arguments (@(
                '-EnableManualReviewHandler'
            ) + (Get-BaseLaunchArgument -Context $context))
        $result.ExitCode | Should -Be 0 -Because $result.StdErr

        $handlerArgv = Get-AgentArgv -Context $context -Role 'review-handler'
        foreach ($capability in @($script:handlerDescriptor.operationalTiers.base)) {
            $handlerArgv | Should -Not -Contain "-$capability"
        }
        $records = Get-DashboardRecord -Context $context
        foreach ($record in $records) { $record.launchMode | Should -BeExactly 'operational' }
        $descriptor = $records[1].descriptor | ConvertFrom-Json -AsHashtable
        @($descriptor.roles.'review-handler'.capabilities | Sort-Object) |
            Should -BeExactly @($script:handlerDescriptor.operationalTiers.base | Sort-Object)
        $result.StdOut | Should -Match 'Mode\s+: OPERATIONAL'
    }

    It 'attaches to an existing launch as a pure observer, launching nothing' {
        $context = New-GoldenContext
        $watchRoot = New-HardenedDirectory $context.WatchRoot
        $priorLaunch = Resolve-AgentTrustedRoot -Path (Join-Path $watchRoot '20200101T000000Z-0000000a') `
            -Kind watch-state -RepositoryRoot $context.Root -Create
        $result = Invoke-GoldenLaunch -Context $context -Arguments @('-AttachOnly', '-StateDir', $priorLaunch)
        $result.ExitCode | Should -Be 0 -Because $result.StdErr
        $records = Get-DashboardRecord -Context $context
        $records.Count | Should -Be 2
        foreach ($record in $records) {
            # Attach passes no launch mode at all, so the launcher's own 'observe' default applies
            # (the fixed mode set itself is asserted against the real launcher in
            # DelegationWidening.Tests.ps1).
            $record.launchMode | Should -BeExactly 'observe'
            @($record.stateDir) | Should -BeExactly @($priorLaunch)
            $record.brokerDescriptorPath | Should -BeExactly ''
        }
        Get-AgentArgv -Context $context -Role 'reviewer' | Should -BeNullOrEmpty
        Get-AgentArgv -Context $context -Role 'review-handler' | Should -BeNullOrEmpty
    }

    It 'keeps the single-role wrappers on their legacy one-cycle preview contract' -ForEach @(
        @{ Wrapper = 'Watch-DevPilotReviewer.ps1'; Role = 'reviewer'; Other = 'review-handler' }
        @{ Wrapper = 'Watch-DevPilotReviewHandler.ps1'; Role = 'review-handler'; Other = 'reviewer' }
    ) {
        $context = New-GoldenContext
        $configParameter = if ($Role -eq 'reviewer') { $context.ReviewerConfig } else { $context.ReviewHandlerConfig }
        $result = Invoke-GoldenLaunch -Context $context -Script $Wrapper `
            -Arguments @('-OperatorAlias', 'golden-test', '-ConfigFile', $configParameter)
        $result.ExitCode | Should -Be 0 -Because $result.StdErr
        $argv = Get-AgentArgv -Context $context -Role $Role
        $argv | Should -Contain '-Once'
        $argv | Should -Not -Contain '-IntervalSeconds'
        Get-AgentArgv -Context $context -Role $Other | Should -BeNullOrEmpty
        (Get-DashboardRecord -Context $context)[0].launchMode | Should -BeExactly 'preview'
    }

    It 'rejects every impossible switch combination and reports them together' -ForEach @(
        @{ Case = @('-Operational', '-PreviewOnly'); Expected = 'PreviewOnly cannot be combined with -Operational' }
        @{ Case = @('-Continuous', '-Once'); Expected = 'Once cannot be combined with -Continuous' }
        @{ Case = @('-Golden', '-ReviewerPullRequestId', '104'); Expected = 'pull request ID cannot be combined with -Continuous' }
        @{ Case = @('-Continuous', '-ReviewHandlerPullRequestId', '104'); Expected = 'pull request ID cannot be combined with -Continuous' }
        @{ Case = @('-PreviewOnly', '-EnableManualReviewerWrites'); Expected = 'PreviewOnly cannot be combined with -EnableManualReviewerWrites' }
        @{ Case = @('-EnableReviewHandlerCodeUpdates'); Expected = 'review-handler code updates require -Operational' }
        @{ Case = @('-Golden', '-Agent', 'Reviewer'); Expected = '-Golden always launches both agents' }
        @{ Case = @('-Golden', '-Agent', 'ReviewHandler'); Expected = '-Golden always launches both agents' }
        @{ Case = @('-Agent', 'ReviewHandler', '-ReviewerPullRequestId', '104'); Expected = 'ReviewerPullRequestId requires -Agent Reviewer or -Agent Both' }
    ) {
        $context = New-GoldenContext
        $result = Invoke-GoldenLaunch -Context $context -Arguments (@($Case) + (Get-BaseLaunchArgument -Context $context))
        $result.ExitCode | Should -Not -Be 0
        $flattened = Get-FlattenedError $result.StdErr
        $flattened | Should -Match ([regex]::Escape($Expected))
        $flattened | Should -Match 'Launch preflight failed'
        # A rejected launch never creates anything.
        Test-Path -LiteralPath $context.WatchRoot | Should -BeFalse
        Get-DashboardRecord -Context $context | Should -BeNullOrEmpty
    }

    It 'reports several problems in one aggregated preflight failure' {
        $context = New-GoldenContext
        $result = Invoke-GoldenLaunch -Context $context -Arguments @('-Continuous', '-Once', '-Operational', '-PreviewOnly',
            '-OperatorAlias', 'golden-test',
            '-ReviewerConfigFile', (Join-Path $context.Root 'agent-config\missing.config.json'),
            '-ReviewHandlerConfigFile', $context.ReviewHandlerConfig)
        $result.ExitCode | Should -Not -Be 0
        $flattened = Get-FlattenedError $result.StdErr
        $flattened | Should -Match 'Launch preflight failed with 3 problem'
        $flattened | Should -Match 'PreviewOnly cannot be combined with -Operational'
        $flattened | Should -Match 'Once cannot be combined with -Continuous'
        $flattened | Should -Match 'Reviewer config was not found'
    }

    It 'validates and discloses under -WhatIf without creating a root, descriptor, or child' {
        $context = New-GoldenContext
        $result = Invoke-GoldenLaunch -Context $context `
            -Arguments (@('-Golden', '-WhatIf') + (Get-BaseLaunchArgument -Context $context))
        $result.ExitCode | Should -Be 0 -Because $result.StdErr
        $result.StdOut | Should -Match 'DevPilot launch plan'
        $result.StdOut | Should -Match 'Mode\s+: OPERATIONAL'
        $result.StdOut | Should -Match 'Manual \(broker\) roles: review-handler, reviewer|Manual \(broker\) roles: reviewer, review-handler'
        Test-Path -LiteralPath $context.WatchRoot | Should -BeFalse
        # WhatIfPreference flows into the recorder's Add-Content, so the validation call is made
        # but its test-only record is intentionally not persisted.
        Get-DashboardRecord -Context $context | Should -BeNullOrEmpty
        Get-AgentArgv -Context $context -Role 'reviewer' | Should -BeNullOrEmpty
        Get-AgentArgv -Context $context -Role 'review-handler' | Should -BeNullOrEmpty
    }

    It 'leaves no residue when the static dashboard runtime preflight fails' {
        $context = New-GoldenContext
        $result = Invoke-GoldenLaunch -Context $context -DashboardExitCode 3 `
            -Arguments (@('-Golden') + (Get-BaseLaunchArgument -Context $context))
        $result.ExitCode | Should -Not -Be 0
        (Get-FlattenedError $result.StdErr) | Should -Match 'Dashboard runtime preflight failed with code 3'
        $records = Get-DashboardRecord -Context $context
        $records.Count | Should -Be 1 -Because (($records | ConvertTo-Json -Depth 4 -Compress) + $result.StdErr)
        $records[0].validateOnly | Should -BeTrue
        $records[0].descriptor | Should -BeExactly ''
        Test-Path -LiteralPath $records[0].stateDir[0] | Should -BeFalse
        Test-Path -LiteralPath $context.WatchRoot | Should -BeFalse
        Get-AgentArgv -Context $context -Role 'reviewer' | Should -BeNullOrEmpty
    }

    It 'removes every newly created root when descriptor-aware dashboard preflight fails' {
        $context = New-GoldenContext
        $result = Invoke-GoldenLaunch -Context $context -DashboardExitCode 3 -DashboardFailCall 2 `
            -Arguments (@('-Golden') + (Get-BaseLaunchArgument -Context $context))
        $result.ExitCode | Should -Not -Be 0
        (Get-FlattenedError $result.StdErr) | Should -Match 'Dashboard preflight failed with code 3'
        $records = Get-DashboardRecord -Context $context
        $records.Count | Should -Be 2
        Test-Path -LiteralPath $records[1].stateDir[0] | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $context.AppData 'DevPilot\state\v2') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $context.AppData 'DevPilot\leases\v1') | Should -BeFalse
        Get-AgentArgv -Context $context -Role 'reviewer' | Should -BeNullOrEmpty
    }

    It 'removes an empty caller-supplied state root created by a failed launch' {
        $context = New-GoldenContext
        $customBase = Join-Path $context.AppData 'custom'
        $customState = Join-Path $customBase 'watch-state'
        $customDurable = Join-Path $customBase 'durable-state'
        $customLease = Join-Path $customBase 'lease'
        $result = Invoke-GoldenLaunch -Context $context -DashboardExitCode 3 -DashboardFailCall 2 `
            -Arguments (@('-Golden', '-StateDir', $customState,
                '-DurableStateRoot', $customDurable, '-LeaseRoot', $customLease) +
                (Get-BaseLaunchArgument -Context $context))
        $result.ExitCode | Should -Not -Be 0
        foreach ($root in @($customState, $customDurable, $customLease)) {
            Test-Path -LiteralPath $root | Should -BeFalse
        }
    }
}

Describe 'cross-launch state history (issue #114)' {
    It 'offers the current launch first, bounds prior launches, and excludes untrusted ones' {
        $context = New-GoldenContext
        $watchRoot = New-HardenedDirectory $context.WatchRoot
        $expected = [Collections.Generic.List[string]]::new()
        # 25 prior launches: only the 20 most recent may be offered.
        foreach ($index in 1..25) {
            $name = '{0:00000000}T000000Z-{1:x8}' -f (20200101 + $index), $index
            $path = Resolve-AgentTrustedRoot -Path (Join-Path $watchRoot $name) -Kind watch-state `
                -RepositoryRoot $context.Root -Create
            [void]$expected.Add($path)
        }
        $newestFirst = @($expected | Sort-Object -Descending)
        $linkTarget = New-HardenedDirectory (Join-Path $TestDrive ([Guid]::NewGuid().ToString('N')))
        $linkPath = Join-Path $watchRoot '20991231T235959Z-deadbeef'
        $linkType = if ($IsWindows) { 'Junction' } else { 'SymbolicLink' }
        New-Item -ItemType $linkType -Path $linkPath -Value $linkTarget | Out-Null
        $unsafePath = $null
        if ($IsWindows) {
            $unsafePath = Join-Path $watchRoot '20991231T235958Z-cafebabe'
            New-Item -ItemType Directory -Path $unsafePath -Force | Out-Null
            $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
            $acl = [Security.AccessControl.DirectorySecurity]::new()
            $acl.SetOwner($identity.User)
            $acl.SetAccessRuleProtection($true, $false)
            $inheritance = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
                [Security.AccessControl.InheritanceFlags]::ObjectInherit
            $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
                    $identity.User, [Security.AccessControl.FileSystemRights]::FullControl, $inheritance,
                    [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Allow))
            $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
                    [Security.Principal.SecurityIdentifier]::new(
                        [Security.Principal.WellKnownSidType]::WorldSid, $null),
                    [Security.AccessControl.FileSystemRights]::Modify, $inheritance,
                    [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Allow))
            Set-Acl -LiteralPath $unsafePath -AclObject $acl
        }

        $result = Invoke-GoldenLaunch -Context $context -Arguments (@('-Golden') + (Get-BaseLaunchArgument -Context $context))
        $result.ExitCode | Should -Be 0 -Because $result.StdErr
        $record = (Get-DashboardRecord -Context $context)[-1]
        $stateDirs = @($record.stateDir)
        $stateDirs.Count | Should -Be 21
        # Current launch first, then the 20 newest trusted prior launches, newest to oldest.
        $stateDirs[0] | Should -Not -BeIn $newestFirst
        (Split-Path $stateDirs[0] -Parent) | Should -BeExactly $watchRoot
        @($stateDirs[1..20]) | Should -BeExactly @($newestFirst[0..19])
        $stateDirs | Should -Not -Contain $linkPath
        # A poisoned prior launch is a warning and an exclusion, never a fatal launch failure.
        # PowerShell renders the warning stream on stdout when the host output is redirected.
        (Get-FlattenedError $result.StdOut) | Should -Match ([regex]::Escape("Excluding prior launch history '$linkPath'"))
        if ($unsafePath) {
            $stateDirs | Should -Not -Contain $unsafePath
            (Get-FlattenedError $result.StdOut) |
                Should -Match ([regex]::Escape("Excluding prior launch history '$unsafePath'"))
        }
        # Durable-state and lease roots are never offered as history.
        foreach ($reserved in @('state', 'leases')) {
            @($stateDirs | Where-Object { $_ -like "*$([IO.Path]::DirectorySeparatorChar)$reserved$([IO.Path]::DirectorySeparatorChar)*" }) |
                Should -BeNullOrEmpty
        }
    }
}

Describe 'broker descriptor absolute-deny validation (issue #114)' {
    BeforeAll {
        function Start-TestBroker {
            param([Parameter(Mandatory)][hashtable]$Context, [Parameter(Mandatory)][hashtable]$Roles)
            $suite = New-HardenedDirectory (Join-Path $TestDrive ([Guid]::NewGuid().ToString('N')))
            $stateRoot = Resolve-AgentTrustedRoot -Path (Join-Path $suite 'watch') -Kind watch-state `
                -RepositoryRoot $Context.Root -Create
            $durableRoot = Resolve-AgentTrustedRoot -Path (Join-Path $suite 'durable') -Kind durable-state `
                -RepositoryRoot $Context.Root -DisallowedRoots @($stateRoot) -Create
            $leaseRoot = Resolve-AgentTrustedRoot -Path (Join-Path $suite 'leases') -Kind lease `
                -RepositoryRoot $Context.Root -DisallowedRoots @($stateRoot, $durableRoot) -Create
            $descriptorPath = Join-Path $stateRoot 'broker.descriptor.v1.json'
            @{
                schemaVersion = 1; ownerProcessId = $PID; stateRoot = $stateRoot
                durableStateRoot = $durableRoot; leaseRoot = $leaseRoot
                operatorAlias = 'golden-test'; roles = $Roles
            } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $descriptorPath -Encoding utf8NoBOM
            if (-not $IsWindows) {
                [IO.File]::SetUnixFileMode($descriptorPath, [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite)
            }
            return Invoke-TimedProcess -FilePath (Resolve-AgentPwshPath) -ArgumentList @(
                '-NoLogo', '-NoProfile', '-NonInteractive', '-File',
                (Join-Path $Context.Root 'tools\Invoke-DevPilotAgentDispatch.ps1'),
                '-DescriptorPath', $descriptorPath) `
                -StandardInputContent ((ConvertTo-AgentCanonicalJson @{
                        schemaVersion = 1; requestId = [Guid]::NewGuid().ToString('D'); operation = 'shutdown'
                    }) + "`n") `
                -CaptureStdOut -CaptureStdErr -TimeoutSeconds 60
        }

        function New-TestRoleEntry {
            param(
                [Parameter(Mandatory)][hashtable]$Context,
                [Parameter(Mandatory)][string]$ScriptRelativePath,
                [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Capabilities,
                [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$MandatoryDenies,
                [AllowNull()][string[]]$AbsoluteDenies
            )
            $entry = @{
                enabled = $true
                configFile = $Context.ReviewerConfig
                configRoot = (Split-Path $Context.ReviewerConfig -Parent)
                scriptPath = (Join-Path $Context.Root $ScriptRelativePath)
                capabilities = $Capabilities
                mandatoryDenies = $MandatoryDenies
            }
            if ($null -ne $AbsoluteDenies) { $entry.absoluteDenies = $AbsoluteDenies }
            return $entry
        }
    }

    It 'accepts a preview-only role policy and a legacy descriptor without absolute denies' -ForEach @(
        @{ Name = 'preview'; Locked = $true }
        @{ Name = 'legacy'; Locked = $false }
    ) {
        $context = New-GoldenContext
        $lock = @(Get-AgentHarnessCapabilityDescriptor -Role reviewer -PreviewOnly).absoluteDenies
        $entry = if ($Locked) {
            New-TestRoleEntry -Context $context -ScriptRelativePath 'src\Agents\reviewer\Start-ReviewerAgent.ps1' `
                -Capabilities @() -MandatoryDenies $lock -AbsoluteDenies $lock
        }
        else {
            New-TestRoleEntry -Context $context -ScriptRelativePath 'src\Agents\reviewer\Start-ReviewerAgent.ps1' `
                -Capabilities @($script:reviewerDescriptor.operationalTiers.base) `
                -MandatoryDenies @($script:reviewerDescriptor.delegableDefaultOff) -AbsoluteDenies $null
        }
        $roles = @{ reviewer = $entry }
        $result = Start-TestBroker -Context $context -Roles $roles
        $result.ExitCode | Should -Be 0 -Because $result.StdErr
        $result.StdOut | Should -Match 'shutdown-complete'
    }

    It 'fails closed on an inconsistent absolute-deny policy' {
        $context = New-GoldenContext
        $cases = @(
            # An absolute deny that is not also a mandatory deny.
            @{
                Capabilities = @(); Mandatory = @($script:reviewerDescriptor.delegableDefaultOff)
                Absolute = @($script:reviewerDescriptor.delegableDefaultOff, 'EnableFindingComments')
            },
            # An absolute deny that is simultaneously an active capability.
            @{
                Capabilities = @('EnableFindingComments')
                Mandatory = @($script:reviewerDescriptor.delegableDefaultOff, 'EnableFindingComments')
                Absolute = @('EnableFindingComments')
            },
            # A name outside everything this role could ever be granted.
            @{
                Capabilities = @(); Mandatory = @($script:reviewerDescriptor.delegableDefaultOff, 'NotACapability')
                Absolute = @('NotACapability')
            }
        )
        foreach ($case in $cases) {
            $roles = @{
                reviewer = New-TestRoleEntry -Context $context `
                    -ScriptRelativePath 'src\Agents\reviewer\Start-ReviewerAgent.ps1' `
                    -Capabilities $case.Capabilities -MandatoryDenies $case.Mandatory -AbsoluteDenies $case.Absolute
            }
            $result = Start-TestBroker -Context $context -Roles $roles
            $result.ExitCode | Should -Not -Be 0 -Because ($case | ConvertTo-Json -Compress)
            (Get-FlattenedError $result.StdErr) | Should -Match 'absolute-deny policy is (inconsistent|malformed)'
        }
    }
}
