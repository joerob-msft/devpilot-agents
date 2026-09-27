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
                    targetRef = 'refs/heads/master'
                    creationDate = [DateTime]::UtcNow.AddMinutes(-$i).ToString('o') }
            }
        )
        $state = @{ rows = $rows; calls = [Collections.Generic.List[string]]::new()
            drift = 0; failPage = 0; failHead = 0
            reorder = $false; duplicate = $false
            noTotal = $false; listCap = 0
            comments = @(); changeLines = 3; omitEvidence = $false; headVisits = @{}
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
                    if ($null -ne $config['pagination']) {
                        $items = @($state.rows | Where-Object {
                                [DateTimeOffset]::Parse($_.creationDate) -lt
                                    [DateTimeOffset]::Parse($request.maxTime)
                            } | Select-Object -First $top)
                    } else {
                        $items = @($state.rows | Select-Object -Skip $request.skip -First $top)
                    }
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
                        commonCommit = 'd' * 40
                        iterationId = $state.iteration }
                }
                Changes {
                    $files = if ($null -eq $state.changeLines -or $state.omitEvidence) {
                        $null
                    } else {
                        @(@{ pathDigest = 'a' * 64; originalPathDigest = $null
                                changeType = 'add'; addedLines = $state.changeLines
                                deletedLines = 0; newLineCount = $state.changeLines
                                spans = @(@{ startLine = 1; endLine = $state.changeLines }) })
                    }
                    $result = @{ changedFiles = 1; changedLines = $state.changeLines
                        baseCommit = $request.commonCommit; files = $null
                        sourceContent = $state.sourceContent }
                    if ($null -ne $files) { $result.files = @($files) }
                    return $result
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
    function New-TestBlob {
        param([string]$Path, [string]$Text)
        $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
        $header = [Text.Encoding]::ASCII.GetBytes("blob $($bytes.Length)`0")
        $hash = [Convert]::ToHexString([Security.Cryptography.SHA1]::HashData(
                [byte[]]($header + $bytes))).ToLowerInvariant()
        return @{ objectId = $hash; path = $Path; gitObjectType = 'blob'
            isFolder = $false; contentMetadata = @{ isBinary = $false
                encoding = 65001; contentType = 'text/plain' }
            content = $Text; rawBytes = $bytes }
    }
    function New-TestTree {
        param([object[]]$Entries)
        $raw = [IO.MemoryStream]::new()
        try {
            foreach ($entry in $Entries) {
                $prefix = [Text.Encoding]::UTF8.GetBytes(
                    "$($entry.mode) $($entry.relativePath)`0")
                $raw.Write($prefix, 0, $prefix.Length)
                $id = [Convert]::FromHexString([string]$entry.objectId)
                $raw.Write($id, 0, $id.Length)
            }
            $bytes = $raw.ToArray()
            $header = [Text.Encoding]::ASCII.GetBytes("tree $($bytes.Length)`0")
            return @{ objectId = [Convert]::ToHexString(
                    [Security.Cryptography.SHA1]::HashData(
                        [byte[]]($header + $bytes))).ToLowerInvariant()
                size = $bytes.Length; treeEntries = $Entries }
        }
        finally { $raw.Dispose() }
    }
    function New-IntakeTransportCase {
        $case = New-IntakeCase -Count 1
        $fixture = @{
            source = 'a' * 40; target = 'b' * 40; common = 'd' * 40
            pages = @{
                '0' = @{ changeEntries = @(); nextSkip = 0 }
                '1' = @{ changeEntries = @(); nextSkip = 0 }
            }
            items = @{}; trees = @{}; rootTreeId = $null
            drift = $false; refDrift = $false; rawIdentityMismatch = $false
        }
        $fixturePath = Join-Path $case.root 'fixture.json'
        $log = Join-Path $case.root 'requests.log'
        $stub = Join-Path $case.root 'az-items-stub.ps1'
        New-Item -ItemType Directory -Path $case.root -Force | Out-Null
        @'
$argv = $args
$fixture = Get-Content -LiteralPath $env:ACTIVE_PR_INTAKE_FIXTURE -Raw |
    ConvertFrom-Json -AsHashtable
$resource = if ($argv[0] -eq 'rest') { 'connectionData' } else {
    $argv[[array]::IndexOf($argv, '--resource') + 1]
}
[IO.File]::AppendAllText($env:ACTIVE_PR_INTAKE_TEST_LOG, ($argv -join '|') + "`n")
$route = @($argv | Where-Object { $_ -like 'pullRequestId=*' })
$skip = @($argv | Where-Object { $_ -like '$skip=*' })
$path = @($argv | Where-Object { $_ -like 'path=*' })
$version = @($argv | Where-Object { $_ -like 'versionDescriptor.version=*' })
switch ($resource) {
    connectionData {
        $answer = @{ authenticatedUser = @{ id = '33333333-3333-3333-3333-333333333333'
            subjectDescriptor = 'aad.synthetic-service-account'
            uniqueName = 'service@example.invalid' } }
    }
    pullRequests {
        $pr = @{ pullRequestId = 1; status = 'active'; isDraft = $false
            sourceRefName = 'refs/heads/feature'; targetRefName = 'refs/heads/master'
            repository = @{ id = '11111111-1111-1111-1111-111111111111'
                project = @{ id = '22222222-2222-2222-2222-222222222222' } } }
        $answer = if ($route.Count) { $pr } else {
            $pageSkip = @($argv | Where-Object { $_ -like '$skip=*' })
            if ($pageSkip.Count -ne 1) { throw 'missing PR page offset' }
            $rows = @()
            if ($pageSkip[0] -eq '$skip=0') { $rows = @($pr) }
            @{ value = $rows; count = $rows.Count }
        }
    }
    pullRequestIterations {
        $prior = @(Get-Content -LiteralPath $env:ACTIVE_PR_INTAKE_TEST_LOG |
            Where-Object { $_ -match '\|pullRequestIterations\|' }).Count
        $source = if ($fixture.drift -and $prior -gt 1) { 'c' * 40 } else { $fixture.source }
        $answer = @{ value = @(@{ id = 1
            sourceRefCommit = @{ commitId = $source }
            targetRefCommit = @{ commitId = $fixture.target }
            commonRefCommit = @{ commitId = $fixture.common } }) }
    }
    refs {
        $prefix = @($argv | Where-Object { $_ -like 'filter=*' })[0] -replace '^filter=', ''
        $prior = @(Get-Content -LiteralPath $env:ACTIVE_PR_INTAKE_TEST_LOG |
            Where-Object { $_ -match '\|pullRequestIterations\|' }).Count
        $source = if ($fixture.drift -and $prior -gt 1) { 'c' * 40 } else { $fixture.source }
        $refs = @(
            @{ name = 'refs/heads/feature'; objectId = $source }
            @{ name = 'refs/heads/master'; objectId = $fixture.target }
        )
        if ($fixture.refDrift -and $prior -gt 1) {
            $refs[1].objectId = 'e' * 40
        }
        $answer = @{ value = @($refs | Where-Object { $_.name -like "refs/$prefix*" }) }
    }
    pullRequestIterationChanges {
        $offset = ($skip[0] -split '=', 2)[1]
        if (-not $fixture.pages.ContainsKey($offset)) { throw 'missing page' }
        $answer = $fixture.pages[$offset]
    }
    items {
        $key = ($version[0] -split '=', 2)[1] + '|' + ($path[0] -split '=', 2)[1]
        if (-not $fixture.items.ContainsKey($key)) { throw 'missing item' }
        $answer = $fixture.items[$key]
    }
    commits {
        $id = @($argv | Where-Object { $_ -like 'commitId=*' })
        if ($id.Count -ne 1 -or $id[0] -ne "commitId=$($fixture.source)") {
            throw 'unbound commit'
        }
        $answer = @{ commitId = $fixture.source; treeId = $fixture.rootTreeId }
    }
    trees {
        $id = @($argv | Where-Object { $_ -like 'sha1=*' })
        if ($id.Count -ne 1 -or
            -not $fixture.trees.ContainsKey(($id[0] -split '=', 2)[1])) {
            throw 'missing tree'
        }
        $answer = $fixture.trees[($id[0] -split '=', 2)[1]]
    }
    pullRequestThreads { $answer = @{ value = @(); count = 0 } }
    default { throw 'A write or unknown resource was attempted' }
}
$answer | ConvertTo-Json -Depth 20 -Compress
'@ | Set-Content -LiteralPath $stub -Encoding utf8
        return @{ case = $case; fixture = $fixture; path = $fixturePath
            log = $log; stub = $stub }
    }
    function Invoke-TransportCase {
        param($Case)
        $Case.fixture | ConvertTo-Json -Depth 20 |
            Set-Content -LiteralPath $Case.path -Encoding utf8
        $env:ACTIVE_PR_INTAKE_FIXTURE = $Case.path
        $env:ACTIVE_PR_INTAKE_TEST_LOG = $Case.log
        try {
            $provider = New-ActivePrAzureDevOpsProvider -Config $Case.case.config `
                -AzureCliPath $Case.stub -RawGet (New-TestRawGet $Case)
            return Invoke-ActivePrIntake -Config $Case.case.config -Provider $provider `
                -StateRoot $Case.case.root -RepositoryRoot $repo -Run
        }
        finally {
            Remove-Item Env:\ACTIVE_PR_INTAKE_FIXTURE, Env:\ACTIVE_PR_INTAKE_TEST_LOG `
                -ErrorAction SilentlyContinue
        }
    }
    function Set-ProjectTreeCase {
        param($Case, [string]$ProjectXml = '<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><IsTestProject>true</IsTestProject></PropertyGroup></Project>')
        $Case.case.config.projectEvidence.enabled = $true
        $source = $Case.fixture.source
        $file = New-TestBlob '/Tests/Fixture.cs' "class Fixture {}`n"
        $project = New-TestBlob '/Tests/Tests.csproj' $ProjectXml
        $Case.fixture.items["$source|/Tests/Fixture.cs"] = $file
        $Case.fixture.items["$source|/Tests/Tests.csproj"] = $project
        $Case.fixture.pages = @{
            '0' = @{ changeEntries = @(
                    @{ changeTrackingId = 1; changeType = 'add'
                        item = @{ path = '/Tests/Fixture.cs'; objectId = $file.objectId } }
                ); nextSkip = 0 }
            '1' = @{ changeEntries = @(); nextSkip = 0 }
        }
        $tests = New-TestTree @(
            @{ relativePath = 'Fixture.cs'; mode = '100644'
                gitObjectType = 'blob'; objectId = $file.objectId }
            @{ relativePath = 'Tests.csproj'; mode = '100644'
                gitObjectType = 'blob'; objectId = $project.objectId }
        )
        $root = New-TestTree @(
            @{ relativePath = 'Tests'; mode = '40000'
                gitObjectType = 'tree'; objectId = $tests.objectId }
        )
        $Case.fixture.rootTreeId = $root.objectId
        $Case.fixture.trees[$root.objectId] = $root
        $Case.fixture.trees[$tests.objectId] = $tests
        return @{ file = $file; project = $project; root = $root; tests = $tests }
    }
    function New-TestRawGet {
        param($Case)
        $fixture = $Case.fixture
        $log = $Case.log
        $config = $Case.case.config
        return {
            param([string]$Operation, [Collections.IDictionary]$RawRequest)
            [IO.File]::AppendAllText($log, "raw|--http-method|GET|$Operation|$($RawRequest.commit)|$($RawRequest.path)`n")
            switch -CaseSensitive ($Operation) {
                Identity {
                    return @{ id = if ($fixture.rawIdentityMismatch) {
                            'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee'
                        } else { $config.expectedAccount.id }
                        descriptor = $config.expectedAccount.descriptor
                        uniqueName = $config.expectedAccount.uniqueName }
                }
                Commit {
                    if ($RawRequest.commit -cne $fixture.source) { throw 'wrong commit' }
                    return @{ commitId = $fixture.source; treeId = $fixture.rootTreeId }
                }
                Tree {
                    if (-not $fixture.trees.ContainsKey([string]$RawRequest.treeId)) {
                        throw 'missing tree'
                    }
                    return $fixture.trees[[string]$RawRequest.treeId]
                }
                Item {
                    $key = "$($RawRequest.commit)|$($RawRequest.path)"
                    if (-not $fixture.items.ContainsKey($key)) { throw 'missing item' }
                    return @{ bytes = [byte[]]$fixture.items[$key].rawBytes }
                }
                default { throw 'unexpected raw operation' }
            }
        }.GetNewClosure()
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
    It 'reconciles 100+ keyset pages without relying on an ADO total count' {
        $c = New-IntakeCase -Count 347 -PageSize 3 -MaxHeads 2
        $c.config.pagination = @{ mode = 'created-time-keyset' }
        $c.state.noTotal = $true
        $e = Invoke-IntakeCase $c
        $e.populationKnown | Should -BeTrue -Because (
            'the keyset traversal must complete: ' + ($e.reasonCodes -join ', '))
        $e.inventory.active | Should -Be 347
        $e.inventory.nonDraft | Should -Be 347
        $e.pages.first | Should -Be 117
        $e.pages.second | Should -Be 117
        $e.inventory.cutoffUtc | Should -Match 'Z$'
        $e.counts.deferred | Should -Be 345
        $e.rules[0].evaluated | Should -Be 0
    }
    It 'fails closed on a keyset boundary tie, duplicate, or split short page' {
        $c = New-IntakeCase -Count 7
        $c.config.pagination = @{ mode = 'created-time-keyset' }
        $c.state.rows[3].creationDate = $c.state.rows[2].creationDate
        $e = Invoke-IntakeCase $c
        $e.populationKnown | Should -BeFalse
        $e.reasonCodes | Should -Contain 'page-cursor-collision'
        $c = New-IntakeCase -Count 7
        $c.config.pagination = @{ mode = 'created-time-keyset' }
        $c.state.rows[4].pullRequestId = 3
        $e = Invoke-IntakeCase $c
        $e.populationKnown | Should -BeFalse
        $e.reasonCodes | Should -Contain 'mutable-page'
        $c = New-IntakeCase -Count 7
        $c.config.pagination = @{ mode = 'created-time-keyset' }
        $c.state.listCap = 2
        $e = Invoke-IntakeCase $c
        $e.populationKnown | Should -BeFalse
        $e.reasonCodes | Should -Contain 'missing-page'
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
        $c = New-IntakeCase -Count 1
        $c.state.omitEvidence = $true
        $e = Invoke-IntakeCase $c
        $e.heads[0].reasonCode | Should -Be 'line-count-unavailable'
        $e.heads[0].lineEvidence | Should -BeNullOrEmpty
        $c = New-IntakeCase -Count 1
        $c.state.changeLines = 0
        $e = Invoke-IntakeCase $c
        $e.heads[0].reasonCode | Should -Be 'unsupported-change'
        $e.heads[0].lineEvidence | Should -BeNullOrEmpty
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
    changeEntries = @($ids | ForEach-Object { @{ changeTrackingId = $_ } })
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
                timeoutMilliseconds = 15000
            }
            $changes.changedFiles | Should -Be 110
            $changes.changedLines | Should -BeNullOrEmpty
            @(Get-Content -LiteralPath $log) | Should -Be @('0', '37', '74', '110')
            $env:ACTIVE_PR_INTAKE_CHANGE_MODE = 'duplicate'
            { & $provider 'Changes' @{
                    pullRequestId = 1; iterationId = 1
                    timeoutMilliseconds = 15000
                } } | Should -Throw 'change-list-truncated'
            $env:ACTIVE_PR_INTAKE_CHANGE_MODE = 'wrong-total'
            { & $provider 'Changes' @{
                    pullRequestId = 1; iterationId = 1
                    timeoutMilliseconds = 15000
                } } | Should -Throw 'change-list-truncated'
            $env:ACTIVE_PR_INTAKE_CHANGE_MODE = ''
            $c.config.limits.maxPages = 3
            { & $provider 'Changes' @{
                    pullRequestId = 1; iterationId = 1
                    timeoutMilliseconds = 15000
                } } | Should -Throw 'change-page-budget'
            $c.config.limits.maxPages = 10
            $c.config.limits.maxChangedFiles = 109
            $capped = New-ActivePrAzureDevOpsProvider -Config $c.config `
                -AzureCliPath $stub
            { & $capped 'Changes' @{
                    pullRequestId = 1; iterationId = 1
                    timeoutMilliseconds = 15000
                } } | Should -Throw 'file-budget'
            $c.config.limits.maxChangedFiles = 200
            $c.config.limits.maxReads = 2
            $readLimited = New-ActivePrAzureDevOpsProvider -Config $c.config `
                -AzureCliPath $stub
            { & $readLimited 'Changes' @{
                    pullRequestId = 1; iterationId = 1
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
    It 'pins Azure CLI transport to GET, organization, project, repository and account' {
        $c = New-IntakeCase -Count 1
        $c.config.enabled = $false
        [void](Invoke-IntakeCase $c)
        New-Item -ItemType Directory -Path $c.root -Force | Out-Null
        $stub = Join-Path $c.root 'az-read-stub.ps1'
        $log = Join-Path $c.root 'az-requests.log'
        $env:ACTIVE_PR_INTAKE_TEST_LOG = $log
        try {
            @'
$CliArguments = $args
[IO.File]::AppendAllText($env:ACTIVE_PR_INTAKE_TEST_LOG, ($CliArguments -join '|') + "`n")
$global:LASTEXITCODE = 0
if ($CliArguments -contains 'connectionData') {
    '{"authenticatedUser":{"id":"33333333-3333-3333-3333-333333333333","subjectDescriptor":"aad.synthetic-service-account","uniqueName":"service@example.invalid"}}'
} elseif ($CliArguments -contains 'rest') {
    '{"authenticatedUser":{"id":"33333333-3333-3333-3333-333333333333","subjectDescriptor":"aad.synthetic-service-account","uniqueName":"service@example.invalid"}}'
} elseif ($CliArguments -contains 'pullRequestIterations') {
    '{"value":[{"id":1,"sourceRefCommit":{"commitId":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"targetRefCommit":{"commitId":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"},"commonRefCommit":{"commitId":"dddddddddddddddddddddddddddddddddddddddd"}}]}'
} elseif ($CliArguments -contains 'refs') {
    '{"value":[{"name":"refs/heads/feature","objectId":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},{"name":"refs/heads/master","objectId":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}]}'
} elseif ($CliArguments -contains 'pullRequestIterationChanges') {
    '{"changeEntries":[],"nextSkip":0}'
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
            $transport = New-ActivePrAzureDevOpsProvider -Config $c.config -AzureCliPath $stub
            $identity = & $transport 'Identity' @{}
            $identity.uniqueName | Should -Be 'service@example.invalid'
            $page = & $transport 'ListPage' @{ pass = 1; skip = 0; top = 3 }
            $page.items[0].pullRequestId | Should -Be 1
            $requests = Get-Content -LiteralPath $log
            $requests.Count | Should -Be 2
            $requests[0] | Should -Match '^rest\|--method\|get\|'
            $requests[0] | Should -Match '/_apis/connectionData\?api-version=7\.1-preview\.1'
            foreach ($request in @($requests | Select-Object -Skip 1)) {
                $request | Should -Match '\|--http-method\|GET\|'
                $request | Should -Match '\|--organization\|https://dev.azure.com/example-org\|'
                $request | Should -Not -Match '\|--http-method\|(POST|PATCH|PUT|DELETE)\||--in-file'
            }
            $requests[1] | Should -Match 'project=ExampleProject'
            $requests[1] | Should -Match 'repositoryId=11111111-1111-1111-1111-111111111111'
            $requests[1] | Should -Match 'searchCriteria.repositoryId=11111111-1111-1111-1111-111111111111'
            { & $transport 'Changes' @{
                    pullRequestId = 1; iterationId = 1; sourceCommit = 'a' * 40
                    targetCommit = 'b' * 40; commonCommit = 'd' * 40
                    remainingReads = 20; timeoutMilliseconds = 30000
                } } | Should -Throw 'unsupported-change'
            $c.config.enabled = $true
            $liveShape = Invoke-ActivePrIntake -Config $c.config -Provider $transport `
                -StateRoot $c.root -RepositoryRoot $repo -Run
            $liveShape.inventory.discovered | Should -Be 1
            $liveShape.heads[0].reasonCode | Should -Be 'unsupported-change'
            $liveShape.heads[0].state | Should -Be 'unknown'
            $liveShape.rules[0].evaluated | Should -Be 0
            $liveShape.rules[0].error | Should -Be 1
            $liveShape.heads[0].lineEvidence | Should -BeNullOrEmpty
            foreach ($request in (Get-Content -LiteralPath $log)) {
                $request | Should -Match '(^rest\|--method\|get\|)|(\|--http-method\|GET\|)'
            }
            if ($IsWindows) {
                $cmd = Join-Path $c.root 'az-read-stub.cmd'
                @'
@echo off
echo {"authenticatedUser":{"id":"33333333-3333-3333-3333-333333333333","uniqueName":"service@example.invalid"}}
'@ | Set-Content -LiteralPath $cmd -Encoding ascii
                $cmdTransport = New-ActivePrAzureDevOpsProvider -Config $c.config -AzureCliPath $cmd
                (& $cmdTransport 'Identity' @{ timeoutMilliseconds = 3000 }).id |
                    Should -Be '33333333-3333-3333-3333-333333333333'
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
                Should -Throw 'byte-budget'
        }
        finally { Remove-Item Env:\ACTIVE_PR_INTAKE_TEST_LOG -ErrorAction SilentlyContinue }
    }
    It 'sends bounded created-time keyset queries using GET and a fixed cutoff' {
        $c = New-IntakeCase -Count 1
        $c.config.pagination = @{ mode = 'created-time-keyset' }
        New-Item -ItemType Directory -Path $c.root -Force | Out-Null
        $stub = Join-Path $c.root 'az-keyset-stub.ps1'
        $log = Join-Path $c.root 'az-keyset-requests.log'
        $env:ACTIVE_PR_INTAKE_TEST_LOG = $log
        try {
            @'
[IO.File]::AppendAllText($env:ACTIVE_PR_INTAKE_TEST_LOG, ($args -join '|') + "`n")
'{"value":[{"pullRequestId":1,"status":"active","isDraft":false,"creationDate":"2024-01-01T12:00:00.1234567Z","targetRefName":"refs/heads/master","repository":{"id":"11111111-1111-1111-1111-111111111111","project":{"id":"22222222-2222-2222-2222-222222222222"}}}],"count":1}'
'@ | Set-Content -LiteralPath $stub -Encoding utf8
            $transport = New-ActivePrAzureDevOpsProvider -Config $c.config `
                -AzureCliPath $stub
            $page = & $transport 'ListPage' @{
                pass = 1; skip = 0; top = 51
                maxTime = '2026-09-27T07:00:00.0000000Z'
                timeoutMilliseconds = 30000
            }
            $page.count | Should -Be 1
            $page.items[0].creationDate | Should -Be '2024-01-01T12:00:00.1234567Z'
            $request = Get-Content -LiteralPath $log -Raw
            $request | Should -Match '\|--http-method\|GET\|'
            $request | Should -Match 'searchCriteria.status=active'
            $request | Should -Match 'searchCriteria.queryTimeRangeType=created'
            $request | Should -Match 'searchCriteria.maxTime=2026-09-27T07:00:00.0000000Z'
            $request | Should -Match '\$skip=0'
            $request | Should -Match '\$top=51'
            { & $transport 'ListPage' @{
                    pass = 1; skip = 1; top = 51
                    maxTime = '2026-09-27T07:00:00.0000000Z'
                } } | Should -Throw 'invalid-page'
        }
        finally {
            Remove-Item Env:\ACTIVE_PR_INTAKE_TEST_LOG -ErrorAction SilentlyContinue
        }
    }
    It 'pages iteration changes and binds verified add/edit/delete/rename spans without retaining source' {
        $t = New-IntakeTransportCase
        $t.fixture.items["$($t.fixture.source)|/added.cs"] = New-TestBlob '/added.cs' "one`ntwo`n"
        $old = New-TestBlob '/edited.cs' "a`nb`nc`n"
        $new = New-TestBlob '/edited.cs' "a`nB`nC`n"
        $t.fixture.items["$($t.fixture.common)|/edited.cs"] = $old
        $t.fixture.items["$($t.fixture.source)|/edited.cs"] = $new
        $deleted = New-TestBlob '/deleted.cs' "gone`n"
        $t.fixture.items["$($t.fixture.common)|/deleted.cs"] = $deleted
        $renamed = New-TestBlob '/renamed.cs' "R`n"
        $original = New-TestBlob '/original.cs' "old`n"
        $t.fixture.items["$($t.fixture.common)|/original.cs"] = $original
        $t.fixture.items["$($t.fixture.source)|/renamed.cs"] = $renamed
        $t.fixture.pages = @{
            '0' = @{ changeEntries = @(
                    @{ changeTrackingId = 1; changeType = 'add'; item = @{ path = '/added.cs'; objectId = $t.fixture.items["$($t.fixture.source)|/added.cs"].objectId } }
                    @{ changeTrackingId = 2; changeType = 'edit'; item = @{ path = '/edited.cs'; objectId = $new.objectId
                            originalObjectId = $old.objectId } }
                ); nextSkip = 2 }
            '2' = @{ changeEntries = @(
                    @{ changeTrackingId = 3; changeType = 'delete'; item = @{ path = '/deleted.cs'; objectId = $deleted.objectId } }
                    @{ changeTrackingId = 4; changeType = 'rename'; originalPath = '/original.cs'
                        item = @{ path = '/renamed.cs'; objectId = $renamed.objectId
                            originalObjectId = $original.objectId } }
                ); nextSkip = 0 }
            '4' = @{ changeEntries = @(); nextSkip = 0 }
        }
        $e = Invoke-TransportCase $t
        $e.heads.Count | Should -BeGreaterThan 0 -Because (@($e.reasonCodes) -join ',')
        $e.heads[0].state | Should -Be 'pending'
        $proof = $e.heads[0].lineEvidence
        $proof.changedFiles | Should -Be 4
        $proof.changedLines | Should -Be 9
        $proof.addedLines | Should -Be 5
        $proof.deletedLines | Should -Be 4
        $proof.baseCommit | Should -Be $t.fixture.common
        $proof.files[0].spans[0].startLine | Should -Be 1
        $proof.files[0].spans[0].endLine | Should -Be 2
        $proof.files[1].spans[0].startLine | Should -Be 2
        $proof.files[1].spans[0].endLine | Should -Be 3
        $proof.files[2].spans.Count | Should -Be 0
        $proof.files[3].spans[0].startLine | Should -Be 1
        $e.heads[0].lineEvidenceDigest | Should -Match '^[a-f0-9]{64}$'
        $e.readCount | Should -BeGreaterThan 10
        ($e | ConvertTo-Json -Depth 32) | Should -Not -Match 'one|gone|original.cs|renamed.cs'
        foreach ($request in (Get-Content -LiteralPath $t.log)) {
            $request | Should -Match '(^rest\|--method\|get\|)|(\|--http-method\|GET\|)'
            $request | Should -Not -Match '\|--http-method\|(POST|PATCH|PUT|DELETE)\||--in-file'
        }
    }
    It 'attests a changed helper against every verified project owner without persisting source' {
        $t = New-IntakeTransportCase
        $graph = Set-ProjectTreeCase $t
        $e = Invoke-TransportCase $t
        $head = $e.heads[0]
        $head.status | Should -Be 'pending' -Because $head.reasonCode
        $head.projectEvidence.complete | Should -BeTrue
        $head.projectEvidence.sourceCommit | Should -Be $t.fixture.source
        $head.projectEvidence.rootTreeId | Should -Be $graph.root.objectId
        $head.projectEvidence.files.Count | Should -Be 1
        $head.projectEvidence.files[0].status | Should -Be 'complete'
        $head.projectEvidence.files[0].objectId | Should -Be $graph.file.objectId
        $head.projectEvidence.files[0].attestationDigest |
            Should -Match '^[a-f0-9]{64}$'
        $head.projectEvidenceDigest | Should -Match '^[a-f0-9]{64}$'
        $saved = Get-Content -LiteralPath (
            Join-Path $t.case.root 'active-pr-intake-v1\cohort.json') -Raw
        $saved | Should -Not -Match 'Fixture\.cs|Tests\.csproj|class Fixture|IsTestProject'
        $log = Get-Content -LiteralPath $t.log
        @($log | Where-Object { $_ -match '\|Commit\|' }).Count | Should -Be 1
        @($log | Where-Object { $_ -match '\|Tree\|' }).Count | Should -Be 2
        foreach ($request in $log) {
            $request | Should -Match '(^rest\|--method\|get\|)|(\|--http-method\|GET\|)'
            $request | Should -Not -Match '\|--http-method\|(POST|PATCH|PUT|DELETE)\|'
        }
    }
    It 'keeps complete mixed ownership distinct from test-only scope' {
        $t = New-IntakeTransportCase
        $graph = Set-ProjectTreeCase $t
        $product = New-TestBlob '/Tests/Product.csproj' @'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup><IsTestProject>false</IsTestProject></PropertyGroup>
</Project>
'@
        $t.fixture.items["$($t.fixture.source)|/Tests/Product.csproj"] = $product
        $tests = New-TestTree @(
            @{ relativePath = 'Fixture.cs'; mode = '100644'
                gitObjectType = 'blob'; objectId = $graph.file.objectId }
            @{ relativePath = 'Product.csproj'; mode = '100644'
                gitObjectType = 'blob'; objectId = $product.objectId }
            @{ relativePath = 'Tests.csproj'; mode = '100644'
                gitObjectType = 'blob'; objectId = $graph.project.objectId }
        )
        $root = New-TestTree @(
            @{ relativePath = 'Tests'; mode = '40000'
                gitObjectType = 'tree'; objectId = $tests.objectId }
        )
        $t.fixture.rootTreeId = $root.objectId
        $t.fixture.trees = @{ $root.objectId = $root; $tests.objectId = $tests }
        $e = Invoke-TransportCase $t
        $e.heads[0].projectEvidence.complete | Should -BeTrue
        $provider = New-ActivePrAzureDevOpsProvider -Config $t.case.config `
            -AzureCliPath $t.stub -RawGet (New-TestRawGet $t)
        $env:ACTIVE_PR_INTAKE_FIXTURE = $t.path
        $env:ACTIVE_PR_INTAKE_TEST_LOG = $t.log
        try {
            $changed = & $provider Changes @{
                pullRequestId = 1; iterationId = 1
                sourceCommit = $t.fixture.source; targetCommit = $t.fixture.target
                commonCommit = $t.fixture.common; includeEvaluationFiles = $true
                includeProjectEvidence = $true; remainingReads = 100
            }
            $owners = $changed.evaluationFiles[0].projectEvidence.projects
            $owners.Count | Should -Be 2
            @($owners | Where-Object isTestProject -eq $true).Count | Should -Be 1
            @($owners | Where-Object isTestProject -eq $false).Count | Should -Be 1
        }
        finally {
            Remove-Item Env:\ACTIVE_PR_INTAKE_FIXTURE, Env:\ACTIVE_PR_INTAKE_TEST_LOG `
                -ErrorAction SilentlyContinue
        }
    }
    It 'fails project scope closed on missing owner, tree truncation, caps and head drift' {
        $t = New-IntakeTransportCase
        $graph = Set-ProjectTreeCase $t
        $t.fixture.trees[$graph.tests.objectId].treeEntries =
            @($graph.tests.treeEntries | Where-Object relativePath -ne 'Tests.csproj')
        $partial = Invoke-TransportCase $t
        $partial.heads[0].projectEvidence.complete | Should -BeFalse
        $partial.heads[0].projectEvidence.files[0].status | Should -Be 'unknown'
        $partial.heads[0].lineEvidence | Should -Not -BeNullOrEmpty

        $t = New-IntakeTransportCase
        $null = Set-ProjectTreeCase $t
        $t.case.config.projectEvidence.maxTreeEntries = 1
        (Invoke-TransportCase $t).heads[0].projectEvidence.complete | Should -BeFalse

        $t = New-IntakeTransportCase
        $null = Set-ProjectTreeCase $t
        $t.fixture.pages['0'].nextSkip = 9
        $brokenPage = Invoke-TransportCase $t
        $brokenPage.heads[0].reasonCode | Should -Be 'change-list-truncated'
        $brokenPage.heads[0].projectEvidence | Should -BeNullOrEmpty

        $t = New-IntakeTransportCase
        $null = Set-ProjectTreeCase $t
        $t.fixture.drift = $true
        $drift = Invoke-TransportCase $t
        $drift.heads[0].reasonCode | Should -Be 'head-drift'
        $drift.heads[0].projectEvidence | Should -BeNullOrEmpty
    }
    It 'uses attested octet-stream bytes rather than rendered item text' {
        $t = New-IntakeTransportCase
        $graph = Set-ProjectTreeCase $t
        $t.fixture.items["$($t.fixture.source)|/Tests/Fixture.cs"].content =
            'rendered text with altered line endings'
        $t.fixture.items["$($t.fixture.source)|/Tests/Tests.csproj"].content =
            'rendered project content is not the Git blob'
        (Invoke-TransportCase $t).heads[0].projectEvidence.complete | Should -BeTrue

        $t = New-IntakeTransportCase
        $null = Set-ProjectTreeCase $t
        $t.fixture.items["$($t.fixture.source)|/Tests/Tests.csproj"].rawBytes =
            [Text.Encoding]::UTF8.GetBytes('<Project><IsTestProject>true</IsTestProject></Project>')
        $corrupt = Invoke-TransportCase $t
        $corrupt.heads[0].projectEvidence.complete | Should -BeFalse
        $corrupt.heads[0].projectEvidence.files[0].status | Should -Be 'unknown'

        $t = New-IntakeTransportCase
        $null = Set-ProjectTreeCase $t
        $t.fixture.rawIdentityMismatch = $true
        $wrongPrincipal = Invoke-TransportCase $t
        $wrongPrincipal.heads[0].reasonCode | Should -Be 'account-mismatch'
        $wrongPrincipal.heads[0].projectEvidence | Should -BeNullOrEmpty
    }
    It 'rejects malformed paging, byte limits and drifting heads without claiming evidence' {
        $t = New-IntakeTransportCase
        (Invoke-TransportCase $t).heads[0].reasonCode | Should -Be 'unsupported-change'
        $t = New-IntakeTransportCase
        $t.fixture.pages['0'] = @{ changeEntries = @(); nextSkip = 1 }
        (Invoke-TransportCase $t).heads[0].reasonCode | Should -Be 'change-list-truncated'
        $t = New-IntakeTransportCase
        $t.fixture.pages['0'] = @{ changeEntries = @(); nextSkip = 0; count = 1 }
        (Invoke-TransportCase $t).heads[0].reasonCode | Should -Be 'change-list-truncated'
        $t = New-IntakeTransportCase
        $t.fixture.pages['0'] = @{ changeEntries = @(
                @{ changeTrackingId = 1; changeType = 'rename'; item = @{ path = '/ambiguous.cs'
                        objectId = 'a' * 40 } }
            ); nextSkip = 0 }
        $t.fixture.pages['1'] = @{ changeEntries = @(); nextSkip = 0 }
        (Invoke-TransportCase $t).heads[0].reasonCode | Should -Be 'unsupported-change'
        $t = New-IntakeTransportCase
        $item = New-TestBlob '/big.cs' "hello`n"
        $t.fixture.items["$($t.fixture.source)|/big.cs"] = $item
        $t.fixture.pages['0'] = @{ changeEntries = @(
                @{ changeTrackingId = 1; changeType = 'add'; item = @{ path = '/big.cs'; objectId = $item.objectId } }
            ); nextSkip = 0 }
        $t.case.config.limits.maxFileBytes = 2
        (Invoke-TransportCase $t).heads[0].reasonCode | Should -Be 'byte-budget'
        $t = New-IntakeTransportCase
        $t.fixture.drift = $true
        $e = Invoke-TransportCase $t
        $e.heads[0].reasonCode | Should -Be 'head-drift'
        $e.heads[0].lineEvidence | Should -BeNullOrEmpty
        $t = New-IntakeTransportCase
        $t.fixture.refDrift = $true
        $e = Invoke-TransportCase $t
        $e.heads[0].reasonCode | Should -Be 'head-inconsistent'
        $e.heads[0].lineEvidence | Should -BeNullOrEmpty
    }
    It 'reconstructs verified UTF-8 BOM bytes and treats line endings as changed lines' {
        $t = New-IntakeTransportCase
        $old = New-TestBlob '/encoding.cs' "a`r`n"
        $old.contentMetadata.encoding = 1252
        $new = New-TestBlob '/encoding.cs' ([string][char]0xfeff + "a`n")
        $new.content = "a`n"
        $t.fixture.items["$($t.fixture.common)|/encoding.cs"] = $old
        $t.fixture.items["$($t.fixture.source)|/encoding.cs"] = $new
        $t.fixture.pages['0'] = @{ changeEntries = @(
                @{ changeTrackingId = 1; changeType = 'edit'; item = @{
                        path = '/encoding.cs'; objectId = $new.objectId
                        originalObjectId = $old.objectId } }
            ); nextSkip = 0 }
        $e = Invoke-TransportCase $t
        $e.heads[0].lineEvidence.changedLines | Should -Be 2
        $e.heads[0].lineEvidence.files[0].spans[0].startLine | Should -Be 1
        $e.heads[0].lineEvidence.files[0].newLineCount | Should -Be 1
    }
    It 'quarantines invalid blob hashes, binary content, zero-line changes and CPU/read exhaustion' {
        $t = New-IntakeTransportCase
        $old = New-TestBlob '/safe.cs' "before`n"
        $new = New-TestBlob '/safe.cs' "after`n"
        $t.fixture.items["$($t.fixture.common)|/safe.cs"] = $old
        $t.fixture.items["$($t.fixture.source)|/safe.cs"] = $new
        $t.fixture.pages['0'] = @{ changeEntries = @(
                @{ changeTrackingId = 1; changeType = 'edit'; item = @{
                        path = '/safe.cs'; objectId = $new.objectId
                        originalObjectId = $old.objectId } }
            ); nextSkip = 0 }
        $t.fixture.items["$($t.fixture.source)|/safe.cs"].content = "spoofed`n"
        (Invoke-TransportCase $t).heads[0].reasonCode | Should -Be 'invalid-item'
        $new = New-TestBlob '/safe.cs' "after`n"
        $t.fixture.items["$($t.fixture.source)|/safe.cs"] = $new
        $t.fixture.items["$($t.fixture.source)|/safe.cs"].contentMetadata.isBinary = $true
        (Invoke-TransportCase $t).heads[0].reasonCode | Should -Be 'invalid-item'
        $new = New-TestBlob '/safe.cs' "after`n"
        $t.fixture.items["$($t.fixture.source)|/safe.cs"] = $new
        $t.case.config.limits.maxTotalBytes = 12
        (Invoke-TransportCase $t).heads[0].reasonCode | Should -Be 'byte-budget'
        $t.case.config.limits.maxTotalBytes = 2097152
        $t.fixture.items["$($t.fixture.source)|/safe.cs"].gitObjectType = 'commit'
        (Invoke-TransportCase $t).heads[0].reasonCode | Should -Be 'invalid-item'
        $new = New-TestBlob '/safe.cs' "after`n"
        $t.fixture.items["$($t.fixture.source)|/safe.cs"] = $new
        $t.case.config.limits.maxDiffCells = 1
        (Invoke-TransportCase $t).heads[0].reasonCode | Should -Be 'diff-budget'
        $t.case.config.limits.maxDiffCells = 1000000
        $t.case.config.limits.maxChangedLines = 1
        (Invoke-TransportCase $t).heads[0].reasonCode | Should -Be 'line-budget'
        $t.case.config.limits.maxChangedLines = 5000
        $t.case.config.limits.maxReads = 6
        (Invoke-TransportCase $t).heads[0].reasonCode | Should -Be 'read-budget'
        $t.case.config.limits.maxReads = 30000
        $t.fixture.items["$($t.fixture.source)|/safe.cs"] = $old
        $t.fixture.pages['0'].changeEntries[0].item.objectId = $old.objectId
        (Invoke-TransportCase $t).heads[0].reasonCode | Should -Be 'unsupported-change'
    }
    It 'diffs long unchanged context under the cell ceiling and keeps deletions off the new side' {
        InModuleScope DevPilot.ActivePrIntake {
            $prefix = "same`n" * 250
            $suffix = "tail`n" * 250
            $deadline = [DateTime]::UtcNow.AddSeconds(10)
            $delta = Get-IntakeLineDelta ($prefix + "old`n" + $suffix) `
                ($prefix + "new`n" + $suffix) 4 1100 $deadline
            $delta.cells | Should -Be 4
            $delta.addedLines | Should -Be 1
            $delta.deletedLines | Should -Be 1
            $delta.spans[0].startLine | Should -Be 251
            $delta.spans[0].endLine | Should -Be 251
            $onlyDeletion = Get-IntakeLineDelta "a`nb`nc`n" "a`nc`n" 4 10 $deadline
            $onlyDeletion.deletedLines | Should -Be 1
            $onlyDeletion.addedLines | Should -Be 0
            $onlyDeletion.spans.Count | Should -Be 0
            { Get-IntakeLineDelta 'old' 'new' 4 2 ([DateTime]::UtcNow.AddSeconds(-1)) } |
                Should -Throw 'time-budget'
        }
    }
}
