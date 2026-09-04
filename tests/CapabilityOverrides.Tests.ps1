BeforeAll {
    Import-Module "$PSScriptRoot\..\src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1" -Force
    $script:brokerPath = (Resolve-Path "$PSScriptRoot\..\tools\Invoke-DevPilotAgentDispatch.ps1").Path
    $script:harnessPath = (Resolve-Path "$PSScriptRoot\..\src\DevPilot.AgentHarness\DevPilot.AgentHarness.psm1").Path
    $script:identity = @{ key = 'v1:github:contoso/widgets'; verified = $true }
    $script:commit = 'a' * 40
    # New-TestRoots below repoints $env:LOCALAPPDATA (and, on non-Windows runners, could repoint
    # $env:XDG_STATE_HOME) at a per-test TestDrive path so every capability-override root resolves
    # underneath it. Environment variables are process-wide and outlive TestDrive, which Pester
    # deletes after this file's run -- without saving/restoring the originals here, a later test
    # FILE in the same Pester process would inherit a dangling reference to a deleted directory.
    $script:originalLocalAppData = $env:LOCALAPPDATA
    $script:originalXdgStateHome = $env:XDG_STATE_HOME

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

AfterAll {
    # Restores the pre-suite values exactly (including removing the variable entirely via $null
    # when it was unset beforehand) so no later test file ever observes a deleted TestDrive path.
    $env:LOCALAPPDATA = $script:originalLocalAppData
    $env:XDG_STATE_HOME = $script:originalXdgStateHome
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

    It 'never interpolates a raw token/secret-shaped or otherwise untrusted name into exception text' {
        # ghp_-shaped: fails the alnum-only capability-name SHAPE check (contains underscores)
        # before ever reaching the dedicated secret-shaped heuristic -- exercises the "malformed
        # name" branch's redaction.
        $tokenShaped = 'ghp_' + ('A1b2C3d4' * 5)
        $bytes = [Text.Encoding]::UTF8.GetBytes(('{"schemaVersion":1,"settings":{"' + $tokenShaped + '":"off"}}'))
        try {
            ConvertFrom-AgentTrustedCapabilityJson -Bytes $bytes -SourceScope machine -AllowedCapabilities @()
            throw 'expected ConvertFrom-AgentTrustedCapabilityJson to throw'
        }
        catch {
            $_.Exception.Message | Should -Match '\[capability-settings-invalid\]'
            $_.Exception.Message | Should -Match 'sha256:[0-9a-f]{12}@\d+'
            $_.Exception.Message | Should -Not -Match ([regex]::Escape($tokenShaped))
        }

        # Pure hex-shaped: passes the alnum-only shape check, so this exercises the dedicated
        # secret-shaped branch instead.
        $hexShaped = ('a1b2c3' * 6)
        $hexBytes = [Text.Encoding]::UTF8.GetBytes(('{"schemaVersion":1,"settings":{"' + $hexShaped + '":"off"}}'))
        try {
            ConvertFrom-AgentTrustedCapabilityJson -Bytes $hexBytes -SourceScope machine -AllowedCapabilities @($hexShaped)
            throw 'expected ConvertFrom-AgentTrustedCapabilityJson to throw'
        }
        catch {
            $_.Exception.Message | Should -Match 'looks secret-shaped'
            $_.Exception.Message | Should -Not -Match ([regex]::Escape($hexShaped))
        }

        # A well-formed but unrecognized name still never echoes the raw name either.
        $unrecognized = 'MadeUpCapabilityXyz'
        $unrecognizedBytes = [Text.Encoding]::UTF8.GetBytes(('{"schemaVersion":1,"settings":{"' + $unrecognized + '":"off"}}'))
        try {
            ConvertFrom-AgentTrustedCapabilityJson -Bytes $unrecognizedBytes -SourceScope machine -AllowedCapabilities @()
            throw 'expected ConvertFrom-AgentTrustedCapabilityJson to throw'
        }
        catch {
            $_.Exception.Message | Should -Match 'not a recognized manually-selectable capability'
            $_.Exception.Message | Should -Not -Match ([regex]::Escape($unrecognized))
        }

        # An unknown top-level field carrying a token-shaped name must be redacted too.
        $unknownFieldBytes = [Text.Encoding]::UTF8.GetBytes(('{"schemaVersion":1,"settings":{},"' + $tokenShaped + '":"x"}'))
        try {
            ConvertFrom-AgentTrustedCapabilityJson -Bytes $unknownFieldBytes -SourceScope machine -AllowedCapabilities @()
            throw 'expected ConvertFrom-AgentTrustedCapabilityJson to throw'
        }
        catch {
            $_.Exception.Message | Should -Match 'Unknown top-level field'
            $_.Exception.Message | Should -Not -Match ([regex]::Escape($tokenShaped))
        }

        # Duplicate/case-collision property-name errors (raised before hashtable conversion, on the
        # raw JSON) must also never echo a token-shaped raw name.
        $dupTokenBytes = [Text.Encoding]::UTF8.GetBytes(
            '{"schemaVersion":1,"settings":{"' + $tokenShaped + '":"off","' + $tokenShaped.ToUpperInvariant() + '":"off"}}')
        try {
            ConvertFrom-AgentTrustedCapabilityJson -Bytes $dupTokenBytes -SourceScope machine -AllowedCapabilities @()
            throw 'expected ConvertFrom-AgentTrustedCapabilityJson to throw'
        }
        catch {
            $_.Exception.Message | Should -Match 'collides case-insensitively'
            $_.Exception.Message | Should -Not -Match ([regex]::Escape($tokenShaped))
        }
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

    It 'fails closed when an existing directory masks a settings file rather than silently resolving as absent' {
        $roots = New-TestRoots
        $overrideRoot = Get-AgentDefaultCapabilityOverrideRoot
        New-Item -ItemType Directory -Path (Join-Path $overrideRoot 'machine.settings.v1.json') -Force | Out-Null
        # Must fail closed (throw), never silently resolve as if the machine scope were unconfigured
        # -- that would be an operator-invisible WIDENING of the effective ceiling.
        { Resolve-AgentEffectiveCapabilitySettings -RepositoryIdentity $identity -RepositoryRoot $roots.RepoRoot `
                -PullRequestId 7 -CurrentSourceCommit $commit } | Should -Throw '*is not a file*'
    }

    It 'Read-AgentStableFile enforces MaxBytes before allocating a buffer, and distinguishes missing from present' {
        $roots = New-TestRoots
        $bigPath = Join-Path $roots.Suite 'oversized.json'
        [IO.File]::WriteAllBytes($bigPath, [byte[]]::new(70000))
        { Read-AgentStableFile -Path $bigPath -MaxBytes 65536 } | Should -Throw '*stable-read-too-large*'

        $smallPath = Join-Path $roots.Suite 'small.json'
        [IO.File]::WriteAllText($smallPath, 'hello', [Text.UTF8Encoding]::new($false))
        $result = Read-AgentStableFile -Path $smallPath -MaxBytes 65536
        $result.Exists | Should -BeTrue
        $result.Size | Should -Be 5
        $result.Bytes.Length | Should -Be 5

        $missingPath = Join-Path $roots.Suite 'missing.json'
        $missingResult = Read-AgentStableFile -Path $missingPath
        $missingResult.Exists | Should -BeFalse
        $missingResult.Bytes.Length | Should -Be 0
    }

    It 'Read-AgentStableFile fails closed rather than treating an existing directory as absent' {
        $roots = New-TestRoots
        $dirPath = Join-Path $roots.Suite 'not-a-file'
        New-Item -ItemType Directory -Path $dirPath -Force | Out-Null
        { Read-AgentStableFile -Path $dirPath } | Should -Throw '*stable-read-invalid*'
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

    It 'holds the capability-override lock around the broker profile/describe resolution, with one bounded retry' {
        $source = Get-Content -LiteralPath $brokerPath -Raw
        $helperBody = [regex]::Match($source, '(?s)function Get-BrokerCapabilityProfile \{.*?\r?\n\}').Value
        $lockIndex = $helperBody.IndexOf('Enter-AgentCapabilityOverrideLock')
        $resolveIndex = $helperBody.IndexOf('Resolve-AgentEffectiveCapabilitySettings')
        $releaseIndex = $helperBody.IndexOf('Exit-AgentLock $capabilityLock.Stream')
        $lockIndex | Should -BeGreaterThan -1
        $resolveIndex | Should -BeGreaterThan $lockIndex
        $releaseIndex | Should -BeGreaterThan $resolveIndex
        # Retries exactly once (a 2-iteration bounded loop) and only for the distinct, explicitly
        # retryable stable-read-unstable signal -- a vanished-file race is never reinterpreted as
        # corrupt/invalid content, and a failed retry must still fail this whole call closed rather
        # than silently falling back to an un-narrowed (wider) ceiling.
        $helperBody | Should -Match '\$resolveAttempt -le 2'
        $helperBody | Should -Match '\[stable-read-unstable\]'
    }

    It 'accepts a manifest whose capabilities were already narrowed relative to the pre-narrowing ceiling' {
        # Regression: the ceiling self-consistency check used to require every post-narrow
        # mandatoryDeny to already be part of the PRE-narrow ceilingMandatoryDenies. That is wrong
        # whenever a capability legitimately moved from ceilingCapabilities into mandatoryDenies via
        # narrowing (exactly what Resolve-AgentCapabilityPolicyPartition does) -- it made the whole
        # feature unusable, rejecting every already-narrowed manifest as "malformed" before the live
        # re-verification (and its lock/retry semantics) was ever reached.
        $roots = New-TestRoots
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
            mandatoryDenies = @('EnableApprovalVote', 'EnableThreadReplies')
            ceilingCapabilities = @('EnableFindingComments', 'EnableThreadReplies', 'EnableSummaryComment')
            ceilingMandatoryDenies = @('EnableApprovalVote')
            configSnapshotSha256 = ('a' * 64)
        }
        $runtimeRoot = Join-Path $roots.Suite 'manual-runtime-narrowed'
        New-Item -ItemType Directory -Path $runtimeRoot -Force | Out-Null
        $manifestPath = Join-Path $runtimeRoot 'dispatch-manifest.json'
        @{
            schemaVersion = 1
            dispatchId = [Guid]::NewGuid().ToString('D')
            role = 'reviewer'
            repositoryKey = $identity.key
            pullRequestId = 9
            capabilityPolicyDigest = Get-AgentCanonicalDigest $policy
            policy = $policy
            startupPipe = (New-AgentPipeName)
            runtimeRoot = $runtimeRoot
            prStateFingerprintSourceCommit = $commit
        } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $manifestPath -Encoding utf8NoBOM

        # Pre-acquire the work lease so a manifest that survives the ceiling self-consistency check
        # (this test's actual target) fails fast and deterministically at the NEXT stage -- lease
        # acquisition, which happens before any prompt/pipe I/O -- rather than needing a real prompt
        # file and a live named-pipe handshake just to prove the ceiling check itself passed.
        $held = Enter-AgentWorkLease -LeaseRoot $leaseRoot -RepositoryIdentity $identity `
            -PullRequestId 9 -Role reviewer -TimeoutMilliseconds 0
        $held.Acquired | Should -BeTrue
        try {
            { Enter-AgentManualDispatchStartup -ManifestPath $manifestPath -RepositoryIdentity $identity `
                    -RepositoryRoot $roots.RepoRoot -DurableContext $context -LeaseRoot $leaseRoot `
                    -Role reviewer -EventLogPath (Join-Path $runtimeRoot 'events.jsonl') `
                    -BoundCapabilities @{
                        EnableFindingComments = $true; EnableSummaryComment = $true
                        EnableThreadReplies = $false; EnableApprovalVote = $false
                    }
            } | Should -Throw '*lease-contended*'
        }
        finally {
            Exit-AgentLock $held.Stream
        }
    }
}

Describe 'PR3 capability-override writer and kill switch' {
    It 'exports the PR3 writer and kill-switch primitives at module scope' {
        foreach ($name in @(
                'Set-AgentCapabilityOverrideSetting', 'Test-AgentCapabilityOverrideKillSwitch',
                'Enable-AgentCapabilityOverrideKillSwitch', 'Disable-AgentCapabilityOverrideKillSwitch')) {
            Get-Command $name -Module DevPilot.AgentHarness | Should -Not -BeNullOrEmpty
        }
    }

    It 'writes off, then reset removes the file entirely with no residue and no leftover temp files' {
        $roots = New-TestRoots
        $allowed = (Get-AgentHarnessCapabilityDescriptor -Role reviewer).allowedManualCapabilities
        $capability = $allowed[0]
        $lock = Enter-AgentCapabilityOverrideLock -RepositoryRoot $roots.RepoRoot
        $lock.Acquired | Should -BeTrue
        try {
            Set-AgentCapabilityOverrideSetting -RepositoryIdentity $identity -RepositoryRoot $roots.RepoRoot `
                -PullRequestId 1 -CurrentSourceCommit $commit -Scope user -Capability $capability -Action off `
                -AllowedCapabilities $allowed
        }
        finally { Exit-AgentLock $lock.Stream }
        $userFile = Join-Path (Get-AgentDefaultCapabilityOverrideRoot) 'user.settings.v1.json'
        Test-Path -LiteralPath $userFile | Should -BeTrue
        $eff = Resolve-AgentEffectiveCapabilitySettings -RepositoryIdentity $identity -RepositoryRoot $roots.RepoRoot `
            -PullRequestId 1 -CurrentSourceCommit $commit
        $eff.Settings[$capability] | Should -BeExactly 'off'
        $eff.Provenance[$capability] | Should -BeExactly 'user'

        $lock2 = Enter-AgentCapabilityOverrideLock -RepositoryRoot $roots.RepoRoot
        try {
            Set-AgentCapabilityOverrideSetting -RepositoryIdentity $identity -RepositoryRoot $roots.RepoRoot `
                -PullRequestId 1 -CurrentSourceCommit $commit -Scope user -Capability $capability -Action inherit `
                -AllowedCapabilities $allowed
        }
        finally { Exit-AgentLock $lock2.Stream }
        Test-Path -LiteralPath $userFile | Should -BeFalse
        $leftover = Get-ChildItem -Path (Get-AgentDefaultCapabilityOverrideRoot) -Recurse -Filter '*.tmp-*' -ErrorAction SilentlyContinue
        $leftover | Should -BeNullOrEmpty
        $effAfter = Resolve-AgentEffectiveCapabilitySettings -RepositoryIdentity $identity -RepositoryRoot $roots.RepoRoot `
            -PullRequestId 1 -CurrentSourceCommit $commit
        $effAfter.Settings.Contains($capability) | Should -BeFalse
    }

    It 'rejects a capability outside the allowed set, including delegableDefaultOff and unknown/case-variant names' {
        $roots = New-TestRoots
        $allowed = (Get-AgentHarnessCapabilityDescriptor -Role reviewer).allowedManualCapabilities
        $lock = Enter-AgentCapabilityOverrideLock -RepositoryRoot $roots.RepoRoot
        try {
            { Set-AgentCapabilityOverrideSetting -RepositoryIdentity $identity -RepositoryRoot $roots.RepoRoot `
                    -PullRequestId 1 -CurrentSourceCommit $commit -Scope user -Capability 'EnableApprovalVote' -Action off `
                    -AllowedCapabilities $allowed
            } | Should -Throw '*narrowing-invalid*'
            { Set-AgentCapabilityOverrideSetting -RepositoryIdentity $identity -RepositoryRoot $roots.RepoRoot `
                    -PullRequestId 1 -CurrentSourceCommit $commit -Scope user -Capability 'NotARealCapability' -Action off `
                    -AllowedCapabilities $allowed
            } | Should -Throw '*narrowing-invalid*'
            { Set-AgentCapabilityOverrideSetting -RepositoryIdentity $identity -RepositoryRoot $roots.RepoRoot `
                    -PullRequestId 1 -CurrentSourceCommit $commit -Scope user -Capability ($allowed[0].ToUpperInvariant()) -Action off `
                    -AllowedCapabilities $allowed
            } | Should -Throw '*narrowing-invalid*'
        }
        finally { Exit-AgentLock $lock.Stream }
    }

    It 'writes a PR-scope record with the correct required binding fields and an expiry in the future' {
        $roots = New-TestRoots
        $allowed = (Get-AgentHarnessCapabilityDescriptor -Role reviewer).allowedManualCapabilities
        $lock = Enter-AgentCapabilityOverrideLock -RepositoryRoot $roots.RepoRoot
        try {
            Set-AgentCapabilityOverrideSetting -RepositoryIdentity $identity -RepositoryRoot $roots.RepoRoot `
                -PullRequestId 42 -CurrentSourceCommit $commit -Scope pr -Capability $allowed[0] -Action off `
                -AllowedCapabilities $allowed
        }
        finally { Exit-AgentLock $lock.Stream }
        $eff = Resolve-AgentEffectiveCapabilitySettings -RepositoryIdentity $identity -RepositoryRoot $roots.RepoRoot `
            -PullRequestId 42 -CurrentSourceCommit $commit
        $eff.Settings[$allowed[0]] | Should -BeExactly 'off'
        $eff.Provenance[$allowed[0]] | Should -BeExactly 'pr'
        # A different PR number must never see this record (deterministic per-PR filename + full-SHA binding).
        $effOtherPr = Resolve-AgentEffectiveCapabilitySettings -RepositoryIdentity $identity -RepositoryRoot $roots.RepoRoot `
            -PullRequestId 43 -CurrentSourceCommit $commit
        $effOtherPr.Settings.Contains($allowed[0]) | Should -BeFalse
    }

    It 'hypothetical-override preview never drifts from what the writer would actually persist' {
        # Same invariant the shared Resolve-AgentCapabilityPolicyPartition primitive already
        # protects: the preview path and the real resolver are the SAME function, so this proves it
        # end-to-end rather than by inspection -- preview a narrowing, apply it for real, and assert
        # the two resolutions agree exactly.
        $roots = New-TestRoots
        $allowed = (Get-AgentHarnessCapabilityDescriptor -Role reviewer).allowedManualCapabilities
        $capability = $allowed[1]
        $hypothetical = @{ Scope = 'repo-worktree'; Capability = $capability; Action = 'off' }
        $preview = Resolve-AgentEffectiveCapabilitySettings -RepositoryIdentity $identity -RepositoryRoot $roots.RepoRoot `
            -PullRequestId 1 -CurrentSourceCommit $commit -HypotheticalOverride $hypothetical
        $lock = Enter-AgentCapabilityOverrideLock -RepositoryRoot $roots.RepoRoot
        try {
            Set-AgentCapabilityOverrideSetting -RepositoryIdentity $identity -RepositoryRoot $roots.RepoRoot `
                -PullRequestId 1 -CurrentSourceCommit $commit -Scope repo-worktree -Capability $capability -Action off `
                -AllowedCapabilities $allowed
        }
        finally { Exit-AgentLock $lock.Stream }
        $applied = Resolve-AgentEffectiveCapabilitySettings -RepositoryIdentity $identity -RepositoryRoot $roots.RepoRoot `
            -PullRequestId 1 -CurrentSourceCommit $commit
        (ConvertTo-AgentCanonicalJson $preview.Settings) | Should -BeExactly (ConvertTo-AgentCanonicalJson $applied.Settings)
        (ConvertTo-AgentCanonicalJson $preview.Provenance) | Should -BeExactly (ConvertTo-AgentCanonicalJson $applied.Provenance)
    }

    It 'kill switch is off by default, masks all persisted narrowing while on, and is idempotent' {
        $roots = New-TestRoots
        $allowed = (Get-AgentHarnessCapabilityDescriptor -Role reviewer).allowedManualCapabilities
        Test-AgentCapabilityOverrideKillSwitch -RepositoryRoot $roots.RepoRoot | Should -BeFalse

        $lock = Enter-AgentCapabilityOverrideLock -RepositoryRoot $roots.RepoRoot
        try {
            Set-AgentCapabilityOverrideSetting -RepositoryIdentity $identity -RepositoryRoot $roots.RepoRoot `
                -PullRequestId 1 -CurrentSourceCommit $commit -Scope machine -Capability $allowed[0] -Action off `
                -AllowedCapabilities $allowed
        }
        finally { Exit-AgentLock $lock.Stream }

        Enable-AgentCapabilityOverrideKillSwitch -RepositoryRoot $roots.RepoRoot
        Enable-AgentCapabilityOverrideKillSwitch -RepositoryRoot $roots.RepoRoot  # idempotent, no throw
        Test-AgentCapabilityOverrideKillSwitch -RepositoryRoot $roots.RepoRoot | Should -BeTrue
        $duringKillSwitch = Resolve-AgentEffectiveCapabilitySettings -RepositoryIdentity $identity -RepositoryRoot $roots.RepoRoot `
            -PullRequestId 1 -CurrentSourceCommit $commit
        $duringKillSwitch.Settings.Count | Should -Be 0
        $duringKillSwitch.KillSwitchActive | Should -BeTrue
        $duringKillSwitch.KillSwitchExpiresAtUtc | Should -BeOfType [long]
        $duringKillSwitch.KillSwitchExpiresAtUtc | Should -BeGreaterThan (ConvertTo-AgentCanonicalEpochSeconds ([DateTime]::UtcNow))

        Disable-AgentCapabilityOverrideKillSwitch -RepositoryRoot $roots.RepoRoot
        Disable-AgentCapabilityOverrideKillSwitch -RepositoryRoot $roots.RepoRoot  # idempotent, no throw
        Test-AgentCapabilityOverrideKillSwitch -RepositoryRoot $roots.RepoRoot | Should -BeFalse
        $afterDisable = Resolve-AgentEffectiveCapabilitySettings -RepositoryIdentity $identity -RepositoryRoot $roots.RepoRoot `
            -PullRequestId 1 -CurrentSourceCommit $commit
        $afterDisable.Settings[$allowed[0]] | Should -BeExactly 'off'
        $afterDisable.KillSwitchActive | Should -BeFalse
        $afterDisable.KillSwitchExpiresAtUtc | Should -BeNullOrEmpty
    }

    It 'emits the kill switch TTL expiry on the shared accessor and cleans up an expired sentinel on next observation' {
        # Protocol-facing coverage (issue #105 PR3 completion) for the emitted-expiry/expired-
        # cleanup gap: Get-AgentCapabilityOverrideKillSwitchExpiresAtUtc is what
        # Invoke-SetKillSwitch's response actually calls, so this exercises the exact same shared
        # sentinel state Resolve-AgentEffectiveCapabilitySettings's KillSwitchExpiresAtUtc uses.
        $roots = New-TestRoots
        Get-AgentCapabilityOverrideKillSwitchExpiresAtUtc -RepositoryRoot $roots.RepoRoot | Should -BeNullOrEmpty

        # Bounds captured immediately around this call (issue #105 PR3 closure), rather than a
        # $nowEpoch snapshot taken before it: a slow first-ever ACL/symlink-hardening pass on a
        # fresh kill-switch root (see Get-AgentCapabilityOverrideKillSwitchState's own doc comment)
        # could otherwise push the wall clock across a second boundary between an earlier snapshot
        # and this call's own internal [DateTime]::UtcNow, intermittently failing a zero-slack
        # upper bound. A bounded 5s slack absorbs that scheduling jitter while still tightly
        # proving the roughly-60s TTL this call actually requests, not some arbitrarily larger one.
        $beforeEpoch = ConvertTo-AgentCanonicalEpochSeconds ([DateTime]::UtcNow)
        Enable-AgentCapabilityOverrideKillSwitch -RepositoryRoot $roots.RepoRoot -TtlSeconds 60
        $afterEpoch = ConvertTo-AgentCanonicalEpochSeconds ([DateTime]::UtcNow)
        $expiresAtUtc = Get-AgentCapabilityOverrideKillSwitchExpiresAtUtc -RepositoryRoot $roots.RepoRoot
        $expiresAtUtc | Should -BeGreaterThan $beforeEpoch
        $expiresAtUtc | Should -BeLessOrEqual ($afterEpoch + 60 + 5)

        # Force expiry without sleeping 60+ seconds: rewrite the sentinel directly to a past epoch,
        # exactly like Write-OverrideFile does for other scope files in this suite.
        $default = Get-AgentDefaultCapabilityOverrideKillSwitchRoot
        $disallowed = @((Get-AgentDefaultDurableStateRoot), (Get-AgentDefaultLeaseRoot), (Get-AgentDefaultWatchStateRoot), (Get-AgentDefaultCapabilityOverrideRoot))
        $killSwitchRoot = Resolve-AgentTrustedRoot -Path $default -Kind capability-overrides -RepositoryRoot $roots.RepoRoot -DisallowedRoots $disallowed
        $sentinelPath = Join-Path $killSwitchRoot 'sentinel.json'
        Test-Path -LiteralPath $sentinelPath -PathType Leaf | Should -BeTrue
        Write-OverrideFile -Path $sentinelPath -Record @{ schemaVersion = 1; enabledAtUtc = ($afterEpoch - 120); expiresAtUtc = ($afterEpoch - 1) }

        Test-AgentCapabilityOverrideKillSwitch -RepositoryRoot $roots.RepoRoot | Should -BeFalse
        Test-Path -LiteralPath $sentinelPath -PathType Leaf | Should -BeFalse
        Get-AgentCapabilityOverrideKillSwitchExpiresAtUtc -RepositoryRoot $roots.RepoRoot | Should -BeNullOrEmpty
    }

    It 'enabling after the sentinel has expired removes it and writes a fresh sentinel instead of treating "a file exists" as still active' {
        # issue #105 PR3 completion (blocker 1): Enable-AgentCapabilityOverrideKillSwitch must
        # itself read/validate the existing sentinel rather than short-circuit on Test-Path --
        # otherwise an expired-but-still-present file (before anything else has observed/cleaned it
        # up) makes a redundant enable call silently return without ever refreshing the TTL.
        $roots = New-TestRoots
        $nowEpoch = ConvertTo-AgentCanonicalEpochSeconds ([DateTime]::UtcNow)
        Enable-AgentCapabilityOverrideKillSwitch -RepositoryRoot $roots.RepoRoot -TtlSeconds 60
        $default = Get-AgentDefaultCapabilityOverrideKillSwitchRoot
        $disallowed = @((Get-AgentDefaultDurableStateRoot), (Get-AgentDefaultLeaseRoot), (Get-AgentDefaultWatchStateRoot), (Get-AgentDefaultCapabilityOverrideRoot))
        $killSwitchRoot = Resolve-AgentTrustedRoot -Path $default -Kind capability-overrides -RepositoryRoot $roots.RepoRoot -DisallowedRoots $disallowed
        $sentinelPath = Join-Path $killSwitchRoot 'sentinel.json'
        Write-OverrideFile -Path $sentinelPath -Record @{ schemaVersion = 1; enabledAtUtc = ($nowEpoch - 120); expiresAtUtc = ($nowEpoch - 1) }

        # The stale, expired file is still present on disk at this point -- nothing has observed it
        # yet -- so this is exactly the "Test-Path sees a file" trap the fix must not fall into.
        Test-Path -LiteralPath $sentinelPath -PathType Leaf | Should -BeTrue

        # Bounds captured immediately around this call (issue #105 PR3 closure), not the
        # $nowEpoch snapshot from the top of the test: several file-I/O-heavy calls run between
        # that snapshot and here, and a bounded 5s slack absorbs any residual scheduling jitter
        # while still tightly proving the roughly-1h (3600s) TTL this call actually requests.
        $beforeEpoch = ConvertTo-AgentCanonicalEpochSeconds ([DateTime]::UtcNow)
        $result = Enable-AgentCapabilityOverrideKillSwitch -RepositoryRoot $roots.RepoRoot -TtlSeconds 3600
        $afterEpoch = ConvertTo-AgentCanonicalEpochSeconds ([DateTime]::UtcNow)
        $result.Active | Should -BeTrue
        $result.ExpiresAtUtc | Should -BeGreaterThan $beforeEpoch
        $result.ExpiresAtUtc | Should -BeLessOrEqual ($afterEpoch + 3600 + 5)
        Test-AgentCapabilityOverrideKillSwitch -RepositoryRoot $roots.RepoRoot | Should -BeTrue
        Get-AgentCapabilityOverrideKillSwitchExpiresAtUtc -RepositoryRoot $roots.RepoRoot | Should -Be $result.ExpiresAtUtc
    }

    It 'enabling an already-active kill switch is idempotent and returns the real, unmodified expiry' {
        $roots = New-TestRoots
        $first = Enable-AgentCapabilityOverrideKillSwitch -RepositoryRoot $roots.RepoRoot -TtlSeconds 3600
        Start-Sleep -Milliseconds 50
        $second = Enable-AgentCapabilityOverrideKillSwitch -RepositoryRoot $roots.RepoRoot -TtlSeconds 3600
        $second.Active | Should -BeTrue
        $second.ExpiresAtUtc | Should -Be $first.ExpiresAtUtc
    }

    It 'a sentinel missing its TTL is never treated as indefinitely active, and Enable fails closed rather than silently replacing it' {
        # issue #105 PR3 completion / review: "missing TTL cannot mean indefinitely active".
        $roots = New-TestRoots
        $default = Get-AgentDefaultCapabilityOverrideKillSwitchRoot
        $disallowed = @((Get-AgentDefaultDurableStateRoot), (Get-AgentDefaultLeaseRoot), (Get-AgentDefaultWatchStateRoot), (Get-AgentDefaultCapabilityOverrideRoot))
        $killSwitchRoot = Resolve-AgentTrustedRoot -Path $default -Kind capability-overrides -RepositoryRoot $roots.RepoRoot -DisallowedRoots $disallowed -Create
        $sentinelPath = Join-Path $killSwitchRoot 'sentinel.json'
        $nowEpoch = ConvertTo-AgentCanonicalEpochSeconds ([DateTime]::UtcNow)
        Write-OverrideFile -Path $sentinelPath -Record @{ schemaVersion = 1; enabledAtUtc = $nowEpoch }

        Test-AgentCapabilityOverrideKillSwitch -RepositoryRoot $roots.RepoRoot | Should -BeFalse
        Get-AgentCapabilityOverrideKillSwitchExpiresAtUtc -RepositoryRoot $roots.RepoRoot | Should -BeNullOrEmpty
        { Enable-AgentCapabilityOverrideKillSwitch -RepositoryRoot $roots.RepoRoot } | Should -Throw '*kill-switch-invalid*'
        # The malformed file must still be there afterward -- Enable- never silently deletes or
        # replaces it; only an operator (or a documented migration) resolves it.
        Test-Path -LiteralPath $sentinelPath -PathType Leaf | Should -BeTrue
    }

    It 'a sentinel with a disallowed extra field or a wrong schemaVersion is rejected the same way as a missing TTL' {
        $roots = New-TestRoots
        $default = Get-AgentDefaultCapabilityOverrideKillSwitchRoot
        $disallowed = @((Get-AgentDefaultDurableStateRoot), (Get-AgentDefaultLeaseRoot), (Get-AgentDefaultWatchStateRoot), (Get-AgentDefaultCapabilityOverrideRoot))
        $killSwitchRoot = Resolve-AgentTrustedRoot -Path $default -Kind capability-overrides -RepositoryRoot $roots.RepoRoot -DisallowedRoots $disallowed -Create
        $sentinelPath = Join-Path $killSwitchRoot 'sentinel.json'
        $nowEpoch = ConvertTo-AgentCanonicalEpochSeconds ([DateTime]::UtcNow)

        Write-OverrideFile -Path $sentinelPath -Record @{ schemaVersion = 2; enabledAtUtc = $nowEpoch; expiresAtUtc = ($nowEpoch + 3600) }
        Test-AgentCapabilityOverrideKillSwitch -RepositoryRoot $roots.RepoRoot | Should -BeFalse
        { Enable-AgentCapabilityOverrideKillSwitch -RepositoryRoot $roots.RepoRoot } | Should -Throw '*kill-switch-invalid*'

        Write-OverrideFile -Path $sentinelPath -Record @{ schemaVersion = 1; enabledAtUtc = $nowEpoch; expiresAtUtc = ($nowEpoch + 3600); extra = 'bogus' }
        Test-AgentCapabilityOverrideKillSwitch -RepositoryRoot $roots.RepoRoot | Should -BeFalse
        { Enable-AgentCapabilityOverrideKillSwitch -RepositoryRoot $roots.RepoRoot } | Should -Throw '*kill-switch-invalid*'
    }

    It 'a sentinel with a fractional schemaVersion is malformed, never silently rounded to a valid version' {
        # issue #105 PR3 closure: PowerShell's own [long] cast banker's-rounds a fractional double
        # (1.1 -> 1), which would otherwise let a corrupted or foreign-schema sentinel masquerade
        # as schemaVersion 1. ConvertTo-AgentCanonicalJson (Write-OverrideFile's own serializer)
        # does not support [double] values at all, so this fixture is written as raw JSON text
        # instead, exactly like the raw-bytes fixtures elsewhere in this file (e.g. the oversized/
        # 'hello' Read-AgentStableFile cases above).
        $roots = New-TestRoots
        $default = Get-AgentDefaultCapabilityOverrideKillSwitchRoot
        $disallowed = @((Get-AgentDefaultDurableStateRoot), (Get-AgentDefaultLeaseRoot), (Get-AgentDefaultWatchStateRoot), (Get-AgentDefaultCapabilityOverrideRoot))
        $killSwitchRoot = Resolve-AgentTrustedRoot -Path $default -Kind capability-overrides -RepositoryRoot $roots.RepoRoot -DisallowedRoots $disallowed -Create
        $sentinelPath = Join-Path $killSwitchRoot 'sentinel.json'
        $nowEpoch = ConvertTo-AgentCanonicalEpochSeconds ([DateTime]::UtcNow)

        [IO.File]::WriteAllText($sentinelPath, "{`"schemaVersion`":1.1,`"enabledAtUtc`":$nowEpoch,`"expiresAtUtc`":$($nowEpoch + 3600)}", [Text.UTF8Encoding]::new($false))
        Test-AgentCapabilityOverrideKillSwitch -RepositoryRoot $roots.RepoRoot | Should -BeFalse
        Get-AgentCapabilityOverrideKillSwitchExpiresAtUtc -RepositoryRoot $roots.RepoRoot | Should -BeNullOrEmpty
        { Enable-AgentCapabilityOverrideKillSwitch -RepositoryRoot $roots.RepoRoot } | Should -Throw '*kill-switch-invalid*'

        # Contrast case: a double that merely HAS a decimal point but is numerically whole (1.0)
        # is still exactly integral -- only a genuine fractional value is rejected.
        [IO.File]::WriteAllText($sentinelPath, "{`"schemaVersion`":1.0,`"enabledAtUtc`":$nowEpoch,`"expiresAtUtc`":$($nowEpoch + 3600)}", [Text.UTF8Encoding]::new($false))
        Test-AgentCapabilityOverrideKillSwitch -RepositoryRoot $roots.RepoRoot | Should -BeTrue
    }

    It 'a sentinel with a huge, NaN-like (infinite), or otherwise out-of-safe-range numeric value is malformed rather than throwing' {
        # issue #105 PR3 closure: PowerShell's own [long] cast THROWS an unhandled RuntimeException
        # on a huge/infinite double instead of failing closed -- ConvertFrom-Json itself turns an
        # oversized exponent like 1e400 into [double]::PositiveInfinity rather than erroring, so
        # this is a real value a corrupted or hostile sentinel can present on the wire.
        $roots = New-TestRoots
        $default = Get-AgentDefaultCapabilityOverrideKillSwitchRoot
        $disallowed = @((Get-AgentDefaultDurableStateRoot), (Get-AgentDefaultLeaseRoot), (Get-AgentDefaultWatchStateRoot), (Get-AgentDefaultCapabilityOverrideRoot))
        $killSwitchRoot = Resolve-AgentTrustedRoot -Path $default -Kind capability-overrides -RepositoryRoot $roots.RepoRoot -DisallowedRoots $disallowed -Create
        $sentinelPath = Join-Path $killSwitchRoot 'sentinel.json'
        $nowEpoch = ConvertTo-AgentCanonicalEpochSeconds ([DateTime]::UtcNow)

        foreach ($expiresAtUtcLiteral in @('1e20', '1e400', '-1e20')) {
            [IO.File]::WriteAllText($sentinelPath, "{`"schemaVersion`":1,`"enabledAtUtc`":$nowEpoch,`"expiresAtUtc`":$expiresAtUtcLiteral}", [Text.UTF8Encoding]::new($false))
            { Test-AgentCapabilityOverrideKillSwitch -RepositoryRoot $roots.RepoRoot } | Should -Not -Throw
            Test-AgentCapabilityOverrideKillSwitch -RepositoryRoot $roots.RepoRoot | Should -BeFalse
            { Enable-AgentCapabilityOverrideKillSwitch -RepositoryRoot $roots.RepoRoot } | Should -Throw '*kill-switch-invalid*'
        }

        # Same guard applies to schemaVersion, not just the timestamp fields.
        [IO.File]::WriteAllText($sentinelPath, "{`"schemaVersion`":1e400,`"enabledAtUtc`":$nowEpoch,`"expiresAtUtc`":$($nowEpoch + 3600)}", [Text.UTF8Encoding]::new($false))
        { Test-AgentCapabilityOverrideKillSwitch -RepositoryRoot $roots.RepoRoot } | Should -Not -Throw
        Test-AgentCapabilityOverrideKillSwitch -RepositoryRoot $roots.RepoRoot | Should -BeFalse
    }

    It 'a sentinel with expiresAtUtc before enabledAtUtc is malformed' {
        $roots = New-TestRoots
        $default = Get-AgentDefaultCapabilityOverrideKillSwitchRoot
        $disallowed = @((Get-AgentDefaultDurableStateRoot), (Get-AgentDefaultLeaseRoot), (Get-AgentDefaultWatchStateRoot), (Get-AgentDefaultCapabilityOverrideRoot))
        $killSwitchRoot = Resolve-AgentTrustedRoot -Path $default -Kind capability-overrides -RepositoryRoot $roots.RepoRoot -DisallowedRoots $disallowed -Create
        $sentinelPath = Join-Path $killSwitchRoot 'sentinel.json'
        $nowEpoch = ConvertTo-AgentCanonicalEpochSeconds ([DateTime]::UtcNow)
        # enabledAtUtc is 1000s ahead of a FUTURE expiresAtUtc so this can never be misclassified as
        # merely 'expired' (which independently also resolves to Active=$false and would mask the
        # real ordering bug this test targets).
        $future = $nowEpoch + 5000
        Write-OverrideFile -Path $sentinelPath -Record @{ schemaVersion = 1; enabledAtUtc = $future; expiresAtUtc = ($future - 100) }

        Test-AgentCapabilityOverrideKillSwitch -RepositoryRoot $roots.RepoRoot | Should -BeFalse
        Get-AgentCapabilityOverrideKillSwitchExpiresAtUtc -RepositoryRoot $roots.RepoRoot | Should -BeNullOrEmpty
        { Enable-AgentCapabilityOverrideKillSwitch -RepositoryRoot $roots.RepoRoot } | Should -Throw '*kill-switch-invalid*'
    }

    It 'a sentinel whose TTL delta is too short (<60s) or too long (>86400s), or whose expiresAtUtc is past the year-2200 ceiling, is malformed' {
        $roots = New-TestRoots
        $default = Get-AgentDefaultCapabilityOverrideKillSwitchRoot
        $disallowed = @((Get-AgentDefaultDurableStateRoot), (Get-AgentDefaultLeaseRoot), (Get-AgentDefaultWatchStateRoot), (Get-AgentDefaultCapabilityOverrideRoot))
        $killSwitchRoot = Resolve-AgentTrustedRoot -Path $default -Kind capability-overrides -RepositoryRoot $roots.RepoRoot -DisallowedRoots $disallowed -Create
        $sentinelPath = Join-Path $killSwitchRoot 'sentinel.json'
        $nowEpoch = ConvertTo-AgentCanonicalEpochSeconds ([DateTime]::UtcNow)
        $future = $nowEpoch + 5000

        # Too short: a 10s TTL is well under Enable-AgentCapabilityOverrideKillSwitch's own 60s
        # floor -- both enabledAtUtc/expiresAtUtc are placed in the future so this can never be
        # misclassified as merely 'expired'.
        Write-OverrideFile -Path $sentinelPath -Record @{ schemaVersion = 1; enabledAtUtc = $future; expiresAtUtc = ($future + 10) }
        Test-AgentCapabilityOverrideKillSwitch -RepositoryRoot $roots.RepoRoot | Should -BeFalse
        { Enable-AgentCapabilityOverrideKillSwitch -RepositoryRoot $roots.RepoRoot } | Should -Throw '*kill-switch-invalid*'

        # Too long: a TTL delta beyond the 86400s ceiling, even though expiresAtUtc alone is still
        # a plausible-looking near-term timestamp (isolates the delta check from the epoch ceiling
        # check below).
        Write-OverrideFile -Path $sentinelPath -Record @{ schemaVersion = 1; enabledAtUtc = $nowEpoch; expiresAtUtc = ($nowEpoch + 90000) }
        Test-AgentCapabilityOverrideKillSwitch -RepositoryRoot $roots.RepoRoot | Should -BeFalse
        { Enable-AgentCapabilityOverrideKillSwitch -RepositoryRoot $roots.RepoRoot } | Should -Throw '*kill-switch-invalid*'

        # Far future: expiresAtUtc itself lands past the shared year-2200 wire ceiling (dashboard's
        # MAX_KILL_SWITCH_EPOCH_SECONDS), with enabledAtUtc chosen so the TTL delta (3600s) stays
        # comfortably inside [60, 86400] -- isolates the epoch-ceiling check from the delta check
        # above.
        $ceiling = 7258118400
        Write-OverrideFile -Path $sentinelPath -Record @{ schemaVersion = 1; enabledAtUtc = ($ceiling - 3500); expiresAtUtc = ($ceiling + 100) }
        Test-AgentCapabilityOverrideKillSwitch -RepositoryRoot $roots.RepoRoot | Should -BeFalse
        { Enable-AgentCapabilityOverrideKillSwitch -RepositoryRoot $roots.RepoRoot } | Should -Throw '*kill-switch-invalid*'
    }

    It 'the kill-switch sentinel root stays disjoint from the versioned v1 override store and every sibling root' {
        $roots = New-TestRoots
        Enable-AgentCapabilityOverrideKillSwitch -RepositoryRoot $roots.RepoRoot
        $killSwitchRoot = Get-AgentDefaultCapabilityOverrideKillSwitchRoot
        $v1Root = Get-AgentDefaultCapabilityOverrideRoot
        Test-AgentPathWithin -Path $killSwitchRoot -Root $v1Root | Should -BeFalse
        Test-AgentPathWithin -Path $v1Root -Root $killSwitchRoot | Should -BeFalse
        foreach ($sibling in @((Get-AgentDefaultDurableStateRoot), (Get-AgentDefaultLeaseRoot), (Get-AgentDefaultWatchStateRoot))) {
            Test-AgentPathWithin -Path $killSwitchRoot -Root $sibling | Should -BeFalse
            Test-AgentPathWithin -Path $sibling -Root $killSwitchRoot | Should -BeFalse
        }
        Disable-AgentCapabilityOverrideKillSwitch -RepositoryRoot $roots.RepoRoot
    }

    It 'two concurrent writers cannot both hold the capability-override lock at once' {
        $roots = New-TestRoots
        $first = Enter-AgentCapabilityOverrideLock -RepositoryRoot $roots.RepoRoot -TimeoutMilliseconds 200
        $first.Acquired | Should -BeTrue
        try {
            $second = Enter-AgentCapabilityOverrideLock -RepositoryRoot $roots.RepoRoot -TimeoutMilliseconds 200
            $second.Acquired | Should -BeFalse
            $second.Reason | Should -BeExactly 'capability-override-contended'
        }
        finally {
            Exit-AgentLock $first.Stream
        }
        $followUp = Enter-AgentCapabilityOverrideLock -RepositoryRoot $roots.RepoRoot -TimeoutMilliseconds 200
        $followUp.Acquired | Should -BeTrue
        Exit-AgentLock $followUp.Stream
    }
}
