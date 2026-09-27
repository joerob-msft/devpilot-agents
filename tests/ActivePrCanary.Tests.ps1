#requires -Version 7.0
BeforeAll {
    $repo = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $repo 'src\DevPilot.ActivePrCanary\DevPilot.ActivePrCanary.psm1') -Force
    Import-Module (Join-Path $repo 'src\DevPilot.ActivePrIntake\DevPilot.ActivePrIntake.psd1')
    Import-Module (Join-Path $repo 'src\DevPilot.RuleEvaluation\DevPilot.RuleEvaluation.psd1')
    $script:roots = [Collections.Generic.List[string]]::new()
    $script:document = @'
## Claim ownership
The owner rule is synthetic for this test.
## Named parameters for Assert
Name the arguments for readability.
## Following section
Outside both sections.
'@
    $script:originalOwnerHash = & (Get-Module DevPilot.ActivePrCanary) {
        $script:OwnerHash
    }
    $hash = & (Get-Module DevPilot.ActivePrCanary) {
        param($Document)
        Get-CanaryTextHash (Get-CanarySection $Document '## Claim ownership')
    } $script:document
    & (Get-Module DevPilot.ActivePrCanary) {
        param($Digest)
        $script:OwnerHash = $Digest
    } $hash
    function New-CanaryCase {
        param([int]$Count = 350, [int]$Selected = 2)
        $root = Join-Path $env:USERPROFILE (
            '.copilot\canary-pester-' + [guid]::NewGuid().ToString('N'))
        $script:roots.Add($root)
        $projectId = '22222222-2222-2222-2222-222222222222'
        $repoId = '11111111-1111-1111-1111-111111111111'
        $engId = '44444444-4444-4444-4444-444444444444'
        $account = @{ id = '33333333-3333-3333-3333-333333333333'
            descriptor = 'aad.synthetic-service-account'
            uniqueName = 'service@example.invalid' }
        $identity = $account.Clone()
        $providerConfig = @{
            provider = 'AzureDevOps'
            repository = @{ organization = 'example-org'
                project = 'ExampleProject'; name = 'ExampleRepo'; id = $repoId }
            projectId = $projectId
            expectedAccount = $account
            operator = @{ defaultAlias = 'service@example.invalid' }
        }
        $owner = @{ approved = $true; projectName = 'Engineering'
            repositoryName = 'EngHub'; repositoryId = $engId
            commit = 'f6db83436b48f48a8521095a888d79f67823bbb2'
            path = '/documentation/EngineeringProcesses/Conventions/AutomatedTests.md'
            modelId = 'synthetic-model' }
        $sources = @{ owner = $owner }
        foreach ($policy in @('test-class-coverage',
                'redundant-method-coverage', 'named-areequal-arguments')) {
            $key = switch ($policy) {
                'test-class-coverage' { 'class' }
                'redundant-method-coverage' { 'redundant' }
                default { 'named' }
            }
            $sources[$key] = @{ approved = $true; projectName = 'ExampleProject'
                repositoryName = 'ExampleRepo'; repositoryId = $repoId
                commit = 'c' * 40
                path = "/src/DevPilot.OwnerCapability/Policy/$policy.v1.txt" }
        }
        $content = "using Microsoft.VisualStudio.TestTools.UnitTesting;`n" +
            "[TestClass]`npublic class Example {`n" +
            "  [TestMethod]`n  public void Test() { Assert.AreEqual(1, 1); }`n}`n"
        $lineCount = @([regex]::Matches($content, '\n')).Count
        $pathText = '/Example.cs'
        $pathDigest = [Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData(
                [Text.Encoding]::UTF8.GetBytes(
                    (ConvertTo-Json -InputObject $pathText -Compress))
            )).ToLowerInvariant()
        $file = @{ pathDigest = $pathDigest; originalPathDigest = $null
            changeType = 'add'; addedLines = $lineCount; deletedLines = 0
            newLineCount = $lineCount
            spans = @(@{ startLine = 1; endLine = $lineCount }) }
        $state = @{ calls = [Collections.Generic.List[string]]::new()
            rows = @(
                for ($i = 1; $i -le $Count; $i++) {
                    @{ pullRequestId = $i; status = 'active'; isDraft = $false
                        targetRef = 'refs/heads/master' }
                }
            )
            drift = 0; driftAfterEvaluation = 0; discussionDrift = 0
            omitPage = $false; omitEvidence = $false
            headVisits = @{}; discussionVisits = @{} }
        $document = $script:document
        $repositoryRoot = $repo
        $provider = {
            param($op, $request)
            $state.calls.Add([string]$op) | Out-Null
            switch -CaseSensitive ($op) {
                Identity { return $identity }
                Metadata {
                    return @{ projectId = $projectId; projectName = 'ExampleProject'
                        repositoryId = $repoId; repositoryName = 'ExampleRepo' }
                }
                ListPage {
                    $items = @($state.rows | Select-Object -Skip $request.skip `
                        -First $request.top)
                    if ($state.omitPage -and $request.pass -eq 2 -and
                        $request.skip -eq 50) { $items = @() }
                    return @{ items = $items; count = $items.Count
                        totalCount = $state.rows.Count }
                }
                Head {
                    $id = [int]$request.pullRequestId
                    if (-not $state.headVisits.ContainsKey($id)) {
                        $state.headVisits[$id] = 0
                    }
                    $state.headVisits[$id]++
                    $sha = if ($state.drift -eq $id -and
                        $state.headVisits[$id] -gt 2 -or
                        $state.driftAfterEvaluation -eq $id -and
                        $state.headVisits[$id] -gt 3) { 'd' * 40 }
                    else { 'a' * 40 }
                    return @{ pullRequestId = $id; repositoryId = $repoId
                        projectId = $projectId; status = 'active'; isDraft = $false
                        sourceRef = 'refs/heads/feature'
                        targetRef = 'refs/heads/master'; sourceCommit = $sha
                        targetCommit = 'b' * 40; commonCommit = 'c' * 40
                        iterationId = 1 }
                }
                Changes {
                    $result = @{ changedFiles = 1
                        changedLines = if ($state.omitEvidence) { $null }
                        else { $lineCount }
                        baseCommit = $request.commonCommit
                        files = @($file) }
                    if ($state.omitEvidence) { $result.files = $null }
                    if ($request.includeEvaluationFiles) {
                        $result.evaluationFiles = @(@{ path = $pathText
                                content = $content; objectId = 'e' * 40 })
                    }
                    return $result
                }
                Discussions {
                    $id = [int]$request.pullRequestId
                    if (-not $state.discussionVisits.ContainsKey($id)) {
                        $state.discussionVisits[$id] = 0
                    }
                    $state.discussionVisits[$id]++
                    if ($state.discussionDrift -eq $id -and
                        $state.discussionVisits[$id] -gt 2) {
                        return @{ count = 1; threads = @(@{
                                    id = 1; status = 'active'
                                    comments = @(@{ id = 1; author = @{
                                                id = '44444444-4444-4444-4444-444444444444'
                                                descriptor = 'aad.other'
                                                uniqueName = 'human@example.invalid' }
                                            commentType = 'text'; content = 'review' })
                                    threadContext = @{
                                        filePath = '/Example.cs'
                                        rightFileStart = @{ line = 5 }
                                        rightFileEnd = @{ line = 5 } }
                                    pullRequestThreadContext = @{
                                        changeTrackingId = 1
                                        iterationContext = @{
                                            firstComparingIteration = 1
                                            secondComparingIteration = 1 } }
                                }) }
                    }
                    return @{ threads = @(); count = 0 }
                }
                RuleSource {
                    $text = if ($request.path -ceq $owner.path) {
                        $document
                    } else {
                        [IO.File]::ReadAllText((Join-Path $repositoryRoot (
                                    $request.path.TrimStart('/') -replace '/', '\')))
                    }
                    return @{ content = $text; projectName = $request.projectName
                        repositoryName = if ($request.path -ceq $owner.path) {
                            'EngHub'
                        } else { 'ExampleRepo' }
                        repositoryId = $request.repositoryId
                        commit = $request.commit; path = $request.path }
                }
                default { throw 'a write or unsupported provider operation was attempted' }
            }
        }.GetNewClosure()
        return @{ root = $root; config = $providerConfig; sources = $sources
            provider = $provider; state = $state
            ids = @(1..$Selected) }
    }
    function Invoke-CanaryCase($Case) {
        Invoke-ActivePrCanaryQualification -ProviderConfig $Case.config `
            -ApprovedSources $Case.sources -StateRoot $Case.root `
            -RepositoryRoot $repo -CanaryPullRequestIds $Case.ids `
            -Provider $Case.provider -Run
    }
}
AfterAll {
    & (Get-Module DevPilot.ActivePrCanary) {
        param($Digest)
        $script:OwnerHash = $Digest
    } $script:originalOwnerHash
    foreach ($root in $script:roots) {
        if (Test-Path -LiteralPath $root) {
            Remove-Item -LiteralPath $root -Recurse -Force
        }
    }
}
Describe 'Explicit signed read-only canary qualification' {
    It 'allows only GET identity and repository metadata during transport bootstrap' {
        $c = New-CanaryCase
        New-Item -ItemType Directory -Path $c.root | Out-Null
        $stub = Join-Path $c.root 'az-stub.ps1'
        $log = Join-Path $c.root 'requests.log'
        @'
$argv = $args
[IO.File]::AppendAllText($env:CANARY_GET_LOG, ($argv -join '|') + "`n")
$resource = if ($argv[0] -eq 'rest') { 'connectionData' } else {
    $argv[[array]::IndexOf($argv, '--resource') + 1]
}
$response = switch ($resource) {
    connectionData {
        @{ authenticatedUser = @{ id = '33333333-3333-3333-3333-333333333333'
            subjectDescriptor = 'aad.synthetic-service-account'
            uniqueName = 'service@example.invalid' } }
    }
    projects { @{ id = '22222222-2222-2222-2222-222222222222'
            name = 'ExampleProject' } }
    repositories {
        @{ id = '11111111-1111-1111-1111-111111111111'; name = 'ExampleRepo'
            project = @{ id = '22222222-2222-2222-2222-222222222222'
                name = 'ExampleProject' } }
    }
    default { throw 'non-bootstrap resource requested' }
}
$response | ConvertTo-Json -Depth 8 -Compress
'@ | Set-Content -LiteralPath $stub -Encoding utf8
        $cfg = Get-Content (Join-Path $repo 'samples\active-pr-intake.config.json') -Raw |
            ConvertFrom-Json -AsHashtable
        $cfg.organization = 'https://dev.azure.com/example-org'
        $cfg.projectName = 'ExampleProject'
        $cfg.projectId = ''
        $cfg.repositoryId = '11111111-1111-1111-1111-111111111111'
        $cfg.repositoryName = 'ExampleRepo'
        $env:CANARY_GET_LOG = $log
        try {
            $provider = New-ActivePrAzureDevOpsProvider -Config $cfg `
                -AzureCliPath $stub -Bootstrap
            (& $provider Identity @{}).uniqueName | Should -Be 'service@example.invalid'
            (& $provider Metadata @{ repositoryName = 'ExampleRepo' }).projectId |
                Should -Be '22222222-2222-2222-2222-222222222222'
            { & $provider ListPage @{ skip = 0; top = 10 } } |
                Should -Throw '*bootstrap-read-not-allowed*'
            { & $provider RuleSource @{} } |
                Should -Throw '*bootstrap-read-not-allowed*'
        }
        finally { Remove-Item Env:\CANARY_GET_LOG }
        $trace = Get-Content -LiteralPath $log
        $trace.Count | Should -Be 3
        @($trace | Where-Object { $_ -notmatch '\b(GET|get)\b' }).Count |
            Should -Be 0
        @($trace | Where-Object { $_ -match '\b(POST|PATCH|PUT|DELETE)\b' }).Count |
            Should -Be 0
    }
    It 'defaults off without provider reads or private state' {
        $c = New-CanaryCase
        $result = Invoke-ActivePrCanaryQualification -ProviderConfig $c.config `
            -ApprovedSources $c.sources -StateRoot $c.root `
            -RepositoryRoot $repo -CanaryPullRequestIds $c.ids `
            -Provider $c.provider
        $result.state | Should -Be 'disabled'
        $c.state.calls.Count | Should -Be 0
        (Test-Path -LiteralPath $c.root) | Should -BeFalse
    }
    It 'derives unconfigured GUIDs from GET metadata and checks the configured reviewer alias' {
        $c = New-CanaryCase
        $c.config.Remove('expectedAccount')
        $c.config.Remove('projectId')
        $result = Invoke-CanaryCase $c
        $result.selected | Should -Be 2
        $intake = Get-Content (Join-Path $c.root 'canary-intake.json') -Raw |
            ConvertFrom-Json -AsHashtable
        $intake.projectId | Should -Be '22222222-2222-2222-2222-222222222222'
        $intake.expectedAccount.id | Should -Be '33333333-3333-3333-3333-333333333333'
        $intake.expectedAccount.uniqueName | Should -Be 'service@example.invalid'
    }
    It 'reconciles 350 paginated heads before evaluating exactly two signed IDs' {
        $c = New-CanaryCase
        $result = Invoke-CanaryCase $c
        $result.inventory.active | Should -Be 350
        $result.inventory.pagesFirst | Should -BeGreaterThan 1
        $result.inventory.pagesSecond | Should -BeGreaterThan 1
        $result.selected | Should -Be 2
        $result.owner | Should -Be 'unknown/not-attempted'
        $result.ruleCounts[0].evaluated | Should -Be 0
        $result.ruleCounts[0].unknown | Should -Be 2
        $result.providerWrites | Should -Be 0
        @($c.state.calls | Where-Object { $_ -in @('Head', 'Changes') }).Count |
            Should -BeGreaterThan 0
        $c.state.headVisits.Count | Should -Be 2
        $config = Get-Content (Join-Path $c.root 'canary-evaluation.json') -Raw |
            ConvertFrom-Json -AsHashtable
        $config.signature | Should -Match '^v1:hmac-sha256:[a-f0-9]{64}$'
        $config.canary.heads.Count | Should -Be 2
        $config.provenance.namedSection.section |
            Should -Be '## Named parameters for Assert'
        $config.rules[1].binding.ruleRepositoryId |
            Should -Be $c.sources.class.repositoryId
        $config.provenance.ownerSection.repositoryId |
            Should -Be $c.sources.owner.repositoryId
        (Get-Content (Join-Path $c.root 'signature.key') -Raw).Length |
            Should -BeGreaterThan 48
        @($c.state.calls | Where-Object { $_ -match 'Write|Post|Patch' }).Count |
            Should -Be 0
    }
    It 'rejects more than two, duplicates, absent, draft or non-master IDs' {
        foreach ($ids in @(@(1, 2, 3), @(1, 1), @(1, 351))) {
            $c = New-CanaryCase
            $c.ids = $ids
            { Invoke-CanaryCase $c } | Should -Throw
            if ($ids.Count -ne 2 -or $ids[0] -eq $ids[1]) {
                $c.state.calls.Count | Should -Be 0
            }
        }
        foreach ($property in @('isDraft', 'targetRef')) {
            $c = New-CanaryCase
            $c.state.rows[0][$property] = if ($property -eq 'isDraft') {
                $true
            } else { 'refs/heads/release' }
            { Invoke-CanaryCase $c } | Should -Throw
            @($c.state.calls | Where-Object RuleSource).Count | Should -Be 0
        }
    }
    It 'fails closed for incomplete inventory, unknown evidence and changed head' {
        foreach ($failure in @('omitPage', 'omitEvidence', 'drift',
                'driftAfterEvaluation', 'discussionDrift')) {
            $c = New-CanaryCase
            if ($failure -in @('drift', 'driftAfterEvaluation', 'discussionDrift')) {
                $c.state[$failure] = 1
            }
            else { $c.state[$failure] = $true }
            if ($failure -in @('drift', 'driftAfterEvaluation', 'discussionDrift')) {
                $result = Invoke-CanaryCase $c
                $result.state | Should -Be 'unknown'
                @($result.ruleCounts | Where-Object unknown -GT 0).Count |
                    Should -BeGreaterThan 0
            } else {
                { Invoke-CanaryCase $c } | Should -Throw
            }
            @($c.state.calls | Where-Object { $_ -match 'Write|Post|Patch' }).Count |
                Should -Be 0
        }
    }
    It 'rejects mismatched reviewer, project and rule source without signing' {
        foreach ($failure in @('reviewer', 'project', 'source')) {
            $c = New-CanaryCase
            switch ($failure) {
                reviewer { $c.config.expectedAccount.uniqueName = 'other@example.invalid'
                    $c.config.operator.defaultAlias = 'other@example.invalid' }
                project { $c.config.projectId = '99999999-9999-9999-9999-999999999999' }
                source { $c.sources.redundant.repositoryName = 'AnotherRepo' }
            }
            { Invoke-CanaryCase $c } | Should -Throw
            (Test-Path (Join-Path $c.root 'signature.key')) | Should -BeFalse
        }
    }
    It 'rejects existing roots, including unrelated user state, and repository-contained roots' {
        $c = New-CanaryCase
        New-Item -ItemType Directory -Path $c.root -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $c.root 'unrelated.json') -Value '{}'
        { Invoke-CanaryCase $c } | Should -Throw '*must-be-new*'
        (Get-Content -LiteralPath (Join-Path $c.root 'unrelated.json') -Raw) |
            Should -Match '\{\}'
        $c.root = Join-Path $repo 'private-canary'
        { Invoke-CanaryCase $c } | Should -Throw '*external*'
    }
    It 'rejects a tampered signed config and mismatched canary generation before ADO reads' {
        $c = New-CanaryCase
        [void](Invoke-CanaryCase $c)
        $intake = Get-Content (Join-Path $c.root 'canary-intake.json') -Raw |
            ConvertFrom-Json -AsHashtable
        $config = Get-Content (Join-Path $c.root 'canary-evaluation.json') -Raw |
            ConvertFrom-Json -AsHashtable
        $key = Get-Content (Join-Path $c.root 'signature.key') -Raw
        $c.state.calls.Clear()
        $config.rules[1].binding.ruleHash = 'v1:sha256:' + ('0' * 64)
        { Invoke-BoundedRuleEvaluation -Config $config -IntakeConfig $intake `
                -Provider $c.provider -StateRoot $c.root -RepositoryRoot $repo `
                -SignatureKey $key -CanaryPullRequestIds $c.ids -Run } |
            Should -Throw '*invalid-signature*'
        $c.state.calls.Count | Should -Be 0
        $config = Get-Content (Join-Path $c.root 'canary-evaluation.json') -Raw |
            ConvertFrom-Json -AsHashtable
        $config.canary.intakeGeneration = '0' * 32
        { Invoke-BoundedRuleEvaluation -Config $config -IntakeConfig $intake `
                -Provider $c.provider -StateRoot $c.root -RepositoryRoot $repo `
                -SignatureKey $key -CanaryPullRequestIds $c.ids -Run } |
            Should -Throw '*invalid-signature*'
        $c.state.calls.Count | Should -Be 0
        $config = Get-Content (Join-Path $c.root 'canary-evaluation.json') -Raw |
            ConvertFrom-Json -AsHashtable
        { Invoke-BoundedRuleEvaluation -Config $config -IntakeConfig $intake `
                -Provider $c.provider -StateRoot $c.root -RepositoryRoot $repo `
                -SignatureKey $key -CanaryPullRequestIds @(3) -Run } |
            Should -Throw '*canary-binding-mismatch*'
        $c.state.calls.Count | Should -Be 0
    }
}
