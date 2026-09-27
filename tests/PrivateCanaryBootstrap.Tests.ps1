#requires -Version 7.0
BeforeAll {
    $repo = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $repo 'src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1')
    Import-Module (Join-Path $repo 'src\OwnerObservationContract\OwnerObservationContract.psd1')
    Import-Module (Join-Path $repo 'src\DevPilot.OwnerAdapters\DevPilot.OwnerAdapters.psd1')
    Import-Module (Join-Path $repo 'src\DevPilot.OwnerCapability\DevPilot.OwnerCapability.psd1')
    Import-Module (Join-Path $repo 'src\DevPilot.ActivePrCanary\DevPilot.ActivePrCanary.psm1') -Force
    Import-Module (Join-Path $repo 'src\DevPilot.ActivePrCanary\DevPilot.PrivateCanaryRunner.psd1') -Force
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Net;
using System.Net.Http;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
public sealed class CanarySyntheticHandler : HttpMessageHandler {
    public List<string> Paths = new List<string>();
    public HttpStatusCode Status = HttpStatusCode.OK;
    public bool FailTransport = false;
    public bool Oversize = false;
    public bool InvalidJson = false;
    protected override Task<HttpResponseMessage> SendAsync(
        HttpRequestMessage request, CancellationToken cancellationToken) {
        if (request.Method != HttpMethod.Get ||
            request.Headers.Authorization?.Scheme != "Bearer" ||
            request.Headers.Authorization?.Parameter != "synthetic-bearer" ||
            request.RequestUri.Host != "dev.azure.com") {
            throw new InvalidOperationException("unbound synthetic GET");
        }
        Paths.Add(request.RequestUri.AbsoluteUri);
        if (FailTransport) {
            throw new HttpRequestException("private transport detail");
        }
        var content = request.RequestUri.AbsolutePath.EndsWith("/connectionData")
            ? Encoding.UTF8.GetBytes("{\"authenticatedUser\":{\"id\":\"33333333-3333-3333-3333-333333333333\",\"subjectDescriptor\":\"aad.synthetic\",\"uniqueName\":\"service@example.invalid\"}}")
            : request.Headers.Accept.ToString() == "application/octet-stream"
            ? Encoding.UTF8.GetBytes("synthetic bytes")
            : Encoding.UTF8.GetBytes("{\"id\":\"synthetic\"}");
        if (Oversize) content = new byte[65537];
        if (InvalidJson) content = Encoding.UTF8.GetBytes("{");
        return Task.FromResult(new HttpResponseMessage(Status) {
            Content = new ByteArrayContent(content)
        });
    }
}
'@
    $module = Get-Module DevPilot.ActivePrCanary
    $script:roots = [Collections.Generic.List[string]]::new()
    $script:old = & $module {
        @{ owner = $script:OwnerHash; named = $script:NamedSectionHash
            namedLength = $script:NamedSectionLength
            coverage = $script:CoverageDocumentHash
            coverageLength = $script:CoverageDocumentLength }
    }
    $script:ownerDocument = "## Claim ownership`nSynthetic owner rule.`n" +
        "## Named parameters for Assert`nSynthetic named rule.`n" +
        "## Following`nNot part of either section.`n"
    $script:coverageDocument = (@('## Synthetic project policy') +
        @('Synthetic convention.') * 219 +
        @('Every class uses an exclusion.', '',
            'Method exclusion is redundant.', '', '## Other', 'End.')) -join "`n"
    function Get-BootstrapHash([byte[]]$Bytes) {
        [Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
    }
    & $module {
        param($OwnerDocument, $CoverageDocument)
        $script:OwnerHash = Get-CanaryTextHash (
            Get-CanarySection $OwnerDocument '## Claim ownership')
        $named = Get-CanaryRawSection $OwnerDocument '## Named parameters for Assert'
        $script:NamedSectionHash = Get-CanaryTextHash $named
        $script:NamedSectionLength = [Text.Encoding]::UTF8.GetByteCount($named)
        $bytes = [Text.Encoding]::UTF8.GetBytes($CoverageDocument)
        $script:CoverageDocumentHash = Get-CanaryHash $bytes
        $script:CoverageDocumentLength = $bytes.Length
    } $script:ownerDocument $script:coverageDocument
    function Get-BootstrapCase {
        $root = Join-Path $env:USERPROFILE (
            '.copilot\private-bootstrap-pester-' + [guid]::NewGuid().ToString('N'))
        $script:roots.Add($root)
        $state = @{
            reads = [Collections.Generic.List[string]]::new()
            wrong = ''
            owner = $script:ownerDocument
            coverage = $script:coverageDocument
            head = '7e6620ec40c9bc37c5a5e13d506053b0139c9206'
            headChecks = 0
        }
        $projectId = '22222222-2222-2222-2222-222222222222'
        $repoId = '11111111-1111-1111-1111-111111111111'
        $engProjectId = '55555555-5555-5555-5555-555555555555'
        $engRepoId = '44444444-4444-4444-4444-444444444444'
        $ownerCommit = 'f6db83436b48f48a8521095a888d79f67823bbb2'
        $provider = {
            param($op, $request)
            $state.reads.Add($op) | Out-Null
            $text = if ($request.commit -ceq $ownerCommit) {
                $state.owner
            } else { $state.coverage }
            $bytes = [Text.Encoding]::UTF8.GetBytes($text)
            $header = [Text.Encoding]::ASCII.GetBytes("blob $($bytes.Length)`0")
            $oid = [Convert]::ToHexString([Security.Cryptography.SHA1]::HashData(
                    [byte[]]($header + $bytes))).ToLowerInvariant()
            switch -CaseSensitive ($op) {
                Identity {
                    return @{ id = '33333333-3333-3333-3333-333333333333'
                        descriptor = if ($state.wrong -eq 'principal-final' -and
                            $state.reads.Count -gt 10) { 'aad.other' }
                        else { 'aad.synthetic' }
                        uniqueName = if ($state.wrong -eq 'principal') {
                            'other@example.invalid'
                        } else { 'service@example.invalid' } }
                }
                Project {
                    if ($request.projectName -ceq 'Engineering') {
                        return @{ id = $engProjectId; name = 'Engineering' }
                    }
                    return @{ id = $projectId
                        name = if ($state.wrong -eq 'project') {
                            'WrongProject'
                        } else { 'ExampleProject' } }
                }
                Repository {
                    if ($request.projectName -ceq 'Engineering') {
                        return @{ id = $engRepoId; name = 'EngHub'
                            project = @{ id = $engProjectId; name = 'Engineering' } }
                    }
                    return @{ id = $repoId
                        name = if ($state.wrong -eq 'repository') {
                            'WrongRepo'
                        } else { 'ExampleRepo' }
                        project = @{ id = $projectId; name = 'ExampleProject' } }
                }
                PullRequest {
                    $state.headChecks++
                    return @{ pullRequestId = 17307009; status = 'active'
                        sourceRefName = 'refs/heads/synthetic-review'
                        repository = @{ id = $engRepoId
                            project = @{ id = $engProjectId; name = 'Engineering' } }
                        lastMergeSourceCommit = @{ commitId = if (
                                $state.wrong -eq 'head-drift' -and
                                $state.headChecks -gt 1) {
                                'a' * 40
                            } else { $state.head } } }
                }
                Iterations {
                    return @{ value = @(@{ id = 1
                                sourceRefCommit = @{ commitId = $state.head } }) }
                }
                Ref {
                    return @{ value = @(@{ name = 'refs/heads/synthetic-review'
                                objectId = $state.head }) }
                }
                Commit {
                    return @{ commitId = if ($state.wrong -eq 'commit') {
                            'a' * 40
                        } else { $request.commit } }
                }
                Item {
                    if ($request.projectName -cne 'Engineering' -or
                        $request.repositoryId -cne $engRepoId -or
                        $request.path -cne
                            '/documentation/EngineeringProcesses/Conventions/AutomatedTests.md') {
                        throw 'wrong source route'
                    }
                    return @{ path = if ($state.wrong -eq 'source-path') {
                            '/wrong-policy.v1.txt'
                        } else { $request.path }
                        gitObjectType = 'blob'
                        objectId = if ($state.wrong -eq 'blob') {
                            'a' * 40
                        } else { $oid } }
                }
                RawItem {
                    if ($state.wrong -eq 'partial') {
                        return @{ bytes = [byte[]]::new(262145) }
                    }
                    return @{ bytes = $bytes }
                }
                default { throw 'unexpected or writing provider operation' }
            }
        }.GetNewClosure()
        return @{ root = $root; state = $state; provider = $provider }
    }
    function Invoke-BootstrapCase($Case) {
        Invoke-PrivateCanaryBootstrap -Organization 'example-org' `
            -ProjectName 'ExampleProject' -RepositoryName 'ExampleRepo' `
            -ExpectedAccountUniqueName 'service@example.invalid' `
            -StateRoot $Case.root -RepositoryRoot $repo -Read $Case.provider -Run
    }
    function Get-RegistryCase {
        $case = Get-BootstrapCase
        [void](Invoke-BootstrapCase $case)
        return @{
            case = $case
            config = Get-Content -LiteralPath (
                Join-Path $case.root 'provider-config.json') -Raw |
                ConvertFrom-Json -AsHashtable
            sources = Get-Content -LiteralPath (
                Join-Path $case.root 'approved-sources.json') -Raw |
                ConvertFrom-Json -AsHashtable
        }
    }
    function Invoke-RegistryCase($InputCase) {
        New-VerifiedCanaryRuleRegistry -ProviderConfig $InputCase.config `
            -ApprovedSources $InputCase.sources -RepositoryRoot $repo `
            -Read $InputCase.case.provider -Run
    }
    function Get-SignedIntakeCase {
        param([switch]$Code)
        $inputCase = Get-RegistryCase
        $root = $inputCase.case.root + '-signed'
        $script:roots.Add($root)
        $state = @{
            calls = [Collections.Generic.List[string]]::new()
            wrong = ''
            visits = 0
            threads = @()
            discussionVisits = 0
            cutoff = $null
            rows = @(
                @{ pullRequestId = 17007699; status = 'active'
                    isDraft = $false; targetRef = 'refs/heads/master'
                    creationDate = [DateTime]::UtcNow.AddMinutes(-4).ToString('o') },
                @{ pullRequestId = 17109075; status = 'active'
                    isDraft = $false; targetRef = 'refs/heads/master'
                    creationDate = [DateTime]::UtcNow.AddMinutes(-5).ToString('o') },
                @{ pullRequestId = 17109076; status = 'active'
                    isDraft = $true; targetRef = 'refs/heads/master'
                    creationDate = [DateTime]::UtcNow.AddMinutes(-6).ToString('o') },
                @{ pullRequestId = 17109077; status = 'active'
                    isDraft = $false; targetRef = 'refs/heads/release'
                    creationDate = [DateTime]::UtcNow.AddMinutes(-7).ToString('o') }
            )
        }
        $config = $inputCase.config
        $path = if ($Code) { '/Tests/Example.cs' } else { '/notes.txt' }
        $content = if ($Code) {
            "using Microsoft.VisualStudio.TestTools.UnitTesting;`n[TestClass]`nclass Example {}`n"
        }
        else { 'synthetic' }
        $bytes = [Text.Encoding]::UTF8.GetBytes($content)
        $header = [Text.Encoding]::ASCII.GetBytes("blob $($bytes.Length)`0")
        $objectId = [Convert]::ToHexString([Security.Cryptography.SHA1]::HashData(
                [byte[]]($header + $bytes))).ToLowerInvariant()
        $digest = [Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData(
                [Text.Encoding]::UTF8.GetBytes(
                    (ConvertTo-Json $path -Compress)))).ToLowerInvariant()
        $state.path = $path
        $state.content = $content
        $state.objectId = $objectId
        $state.lines = if ($Code) { 3 } else { 1 }
        $state.code = [bool]$Code
        $provider = {
            param($op, $request)
            $state.calls.Add($op) | Out-Null
            switch -CaseSensitive ($op) {
                Identity {
                    return $config.expectedAccount
                }
                ListPage {
                    if ($request.skip -ne 0 -or $request.top -ne 51 -or
                        [string]$request.maxTime -cnotmatch
                            '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{7}Z$') {
                        throw 'unbounded or offset inventory'
                    }
                    if ($null -eq $state.cutoff) {
                        $state.cutoff = [string]$request.maxTime
                    } elseif ($request.pass -eq 2 -and
                        $request.maxTime -gt $state.cutoff) {
                        throw 'changed inventory cutoff'
                    }
                    if ($state.wrong -eq 'split-page' -and
                        $request.pass -eq 2 -and $request.skip -eq 0) {
                        return @{ items = @($state.rows[0]); count = 1
                            totalCount = 1 }
                    }
                    $items = @($state.rows | Where-Object {
                            [DateTimeOffset]::Parse($_.creationDate) -lt
                            [DateTimeOffset]::Parse($request.maxTime)
                        } | Select-Object -First $request.top)
                    return @{ items = $items; count = $items.Count }
                }
                Head {
                    $state.visits++
                    $id = [int]$request.pullRequestId
                    $row = @($state.rows | Where-Object pullRequestId -EQ $id)[0]
                    return @{ pullRequestId = $id
                        repositoryId = $config.repository.id
                        projectId = $config.projectId
                        status = 'active'; isDraft = $false
                        sourceRef = 'refs/heads/feature'
                        targetRef = $row.targetRef
                        sourceCommit = if ($state.wrong -eq 'stale-head' -and
                            $state.visits -gt 1) { 'f' * 40 } else { 'a' * 40 }
                        targetCommit = 'b' * 40
                        commonCommit = 'c' * 40; iterationId = 1 }
                }
                Changes {
                    if ($state.wrong -eq 'provider-drift') {
                        $config.expectedAccount.uniqueName = 'other@example.invalid'
                    }
                    $graph = if ($state.code) {
                        @{
                            schemaVersion = 1
                            kind = 'source-bound-evaluated-project-graph-v1'
                            repositoryId = $config.repository.id
                            sourceCommit = $request.sourceCommit
                            path = $state.path
                            objectId = $state.objectId
                            complete = $true
                            projects = @(@{
                                    path = '/Tests/Tests.csproj'
                                    objectId = 'e' * 40
                                    compileIncluded = $true
                                    isTestProject = $true
                                })
                        }
                    } else { $null }
                    if ($graph -and $state.wrong -eq 'mixed-project') {
                        $graph.projects += @{
                            path = '/Product/Product.csproj'
                            objectId = 'a' * 40
                            compileIncluded = $true
                            isTestProject = $false
                        }
                    }
                    $file = @{ path = $state.path
                        content = if ($state.wrong -eq 'blob-content') {
                            $state.content + 'tampered'
                        } else { $state.content }
                        objectId = $state.objectId }
                    if ($graph) { $file.projectEvidence = $graph }
                    $receipt = @()
                    if ($graph) {
                        $receipt = @(@{ pathDigest = $digest
                                objectId = $state.objectId
                                status = 'complete'
                                attestationDigest = [Convert]::ToHexString(
                                    [Security.Cryptography.SHA256]::HashData(
                                        [Text.Encoding]::UTF8.GetBytes(
                                            (ConvertTo-Json $graph -Depth 32 -Compress))
                                    )).ToLowerInvariant() })
                    }
                    return @{ changedFiles = 1; changedLines = $state.lines
                        baseCommit = $request.commonCommit
                        files = @(@{ pathDigest = $digest
                                originalPathDigest = $null; changeType = 'add'
                                addedLines = $state.lines; deletedLines = 0
                                newLineCount = $state.lines
                                spans = @(@{ startLine = 1; endLine = $state.lines }) })
                        evaluationFiles = @($file)
                        projectEvidence = @{
                            schemaVersion = 1
                            kind = 'source-bound-project-scope-summary-v1'
                            repositoryId = $config.repository.id
                            sourceCommit = if ($state.wrong -eq 'fake-graph') {
                                'f' * 40
                            } else { $request.sourceCommit }
                            rootTreeId = if ($state.code) { 'f' * 40 } else { $null }
                            complete = $true; files = $receipt
                        } }
                }
                Discussions {
                    $state.discussionVisits++
                    $threads = @($state.threads)
                    if ($state.wrong -eq 'discussion-drift' -and
                        $state.discussionVisits -gt 1) {
                        $threads = @()
                    }
                    return @{ threads = $threads; count = $threads.Count }
                }
                default { throw 'unexpected or writing provider operation' }
            }
        }.GetNewClosure()
        $baseline = $inputCase.case.state.headChecks
        $read = {
            param($operation, $request)
            if ($state.wrong -eq 'late-head' -and
                $operation -ceq 'PullRequest' -and
                $inputCase.case.state.headChecks -ge ($baseline + 2)) {
                $inputCase.case.state.head = 'f' * 40
            }
            & $inputCase.case.provider $operation $request
        }.GetNewClosure()
        return @{ input = $inputCase; root = $root; state = $state
            read = $read; provider = $provider }
    }
    function Invoke-SignedIntakeCase($Case) {
        Invoke-PrivateCanarySignedIntake -ProviderConfig $Case.input.config `
            -ApprovedSources $Case.input.sources -StateRoot $Case.root `
            -RepositoryRoot $repo -CanaryPullRequestIds @(17007699, 17109075) `
            -Read $Case.read -Provider $Case.provider -Run
    }
    function Invoke-RunnerCase($Case) {
        Invoke-PrivateCanaryEvaluation -StateRoot $Case.root `
            -RepositoryRoot $repo -Read $Case.read -Provider $Case.provider -Run
    }
    function New-RunnerThread($Case, [int]$Id, [string]$Body,
        [switch]$Outdated) {
        return @{
            id = $Id; status = 'active'
            comments = @(@{ id = 1; author = $Case.input.config.expectedAccount
                    commentType = 'text'; content = $Body })
            threadContext = @{ filePath = $Case.state.path
                rightFileStart = @{ line = 3 }; rightFileEnd = @{ line = 3 } }
            pullRequestThreadContext = @{
                changeTrackingId = 1
                iterationContext = @{
                    firstComparingIteration = if ($Outdated) { 0 } else { 1 }
                    secondComparingIteration = if ($Outdated) { 0 } else { 1 }
                }
            }
        }
    }
    function Get-RunnerClassMarkerBody($Case) {
                $config = Get-Content -LiteralPath (
                    Join-Path $Case.root 'canary-dispatcher.json') -Raw |
                    ConvertFrom-Json -AsHashtable -Depth 32
                $sources = Get-Content -LiteralPath (
                    Join-Path $Case.root 'approved-sources.json') -Raw |
                    ConvertFrom-Json -AsHashtable -Depth 32
                $cohort = Get-Content -LiteralPath (
                    Join-Path $Case.root 'active-pr-intake-v1\cohort.json') -Raw |
                    ConvertFrom-Json -AsHashtable -Depth 32
                $head = $cohort.heads[0].declaration
                $ruleId = 'bpm-test-class-coverage@2'
                $source = $sources.rules[$ruleId]
                $rule = @($config.rules | Where-Object capabilityId -CEQ $ruleId)[0]
                $changes = & $Case.provider Changes @{
                    pullRequestId = $head.pullRequestId
                    sourceCommit = $head.sourceCommit; commonCommit = $head.commonCommit
                }
                $graph = $changes.evaluationFiles[0].projectEvidence
                $digest = Get-BootstrapHash ([Text.Encoding]::UTF8.GetBytes(
                        (ConvertTo-Json -InputObject $graph -Depth 32 -Compress)))
                $identity = @($ruleId, $Case.state.path, 'Example', 3, 3, $digest)
                $constructRef = 'construct:' + (Get-BootstrapHash (
                        [Text.Encoding]::UTF8.GetBytes(
                            (ConvertTo-Json -InputObject $identity -Depth 32 -Compress))))
                $finding = @{
                    disposition = 'violation'; constructRef = $constructRef
                    anchor = @{ path = 'Tests/Example.cs'; line = 3; symbol = 'Example' }
                    binding = (New-OwnerCanonicalAnchor -Path 'Tests/Example.cs' `
                            -StartLine 3 -Symbol 'Example' -ConstructIdentity $constructRef)
                }
                $contract = New-OwnerAcquisitionContract `
                    -RepositoryId $head.repositoryId -ProjectId $head.projectId `
                    -PullRequestId $head.pullRequestId -SourceCommit $head.sourceCommit `
                    -TargetCommit $head.targetCommit -TargetRef $head.targetRef `
                    -RuleRepositoryId $source.repositoryId `
                    -RulePath $source.path.TrimStart('/') -RuleCommit $source.commit `
                    -RuleSection $ruleId -RuleHash $rule.sourceHash -RuleLength 16286 `
                    -ConfigId 'private-canary-signed-intake-v1' `
                    -ConfigDigest ('v1:sha256:' + (Get-BootstrapHash (
                                [Text.Encoding]::UTF8.GetBytes(
                                    (ConvertTo-AgentCanonicalJson $config))))) `
                    -CapabilityId $ruleId -CapabilityDigest $rule.declarationDigest
                $marker = Get-TestClassCoverageMarkerKey $contract $finding
                return Format-TestClassCoverageComment $contract $finding $marker
    }
    function Set-RunnerFile($Case, [string]$Name, [scriptblock]$Mutate) {
        $path = Join-Path $Case.root $Name
        $document = Get-Content -LiteralPath $path -Raw |
            ConvertFrom-Json -AsHashtable -Depth 32
        & $Mutate $document
        [IO.File]::WriteAllText($path, (ConvertTo-Json $document -Depth 32))
    }
    function Sign-RunnerConfig($Case, [scriptblock]$Mutate) {
        $path = Join-Path $Case.root 'canary-dispatcher.json'
        $document = Get-Content -LiteralPath $path -Raw |
            ConvertFrom-Json -AsHashtable -Depth 32
        & $Mutate $document
        $key = Get-Content -LiteralPath (Join-Path $Case.root 'signature.key') -Raw
        $unsigned = [ordered]@{}
        foreach ($name in $document.Keys) {
            if ($name -cne 'signature') { $unsigned[$name] = $document[$name] }
        }
        $hmac = [Security.Cryptography.HMACSHA256]::new(
            [Text.Encoding]::UTF8.GetBytes($key))
        try {
            $document.signature = 'v1:hmac-sha256:' +
                [Convert]::ToHexString($hmac.ComputeHash(
                        [Text.Encoding]::UTF8.GetBytes(
                            (ConvertTo-AgentCanonicalJson $unsigned))
                    )).ToLowerInvariant()
        }
        finally { $hmac.Dispose() }
        [IO.File]::WriteAllText($path, (ConvertTo-Json $document -Depth 32))
    }
}
AfterAll {
    & (Get-Module DevPilot.ActivePrCanary) {
        param($Previous)
        $script:OwnerHash = $Previous.owner
        $script:NamedSectionHash = $Previous.named
        $script:NamedSectionLength = $Previous.namedLength
        $script:CoverageDocumentHash = $Previous.coverage
        $script:CoverageDocumentLength = $Previous.coverageLength
    } $script:old
    foreach ($root in $script:roots) {
        if (Test-Path -LiteralPath $root) {
            Remove-Item -LiteralPath $root -Recurse -Force
        }
    }
}
Describe 'Read-only private canary input bootstrap' {
    Describe 'Signed GET-only candidate evaluation runner' {
        It 'remains disabled without opening even a nonexistent private root' {
            $c = Get-SignedIntakeCase
            $result = Invoke-PrivateCanaryEvaluation -StateRoot $c.root `
                -RepositoryRoot $repo -Read $c.read -Provider $c.provider
            $result.state | Should -Be 'disabled'
            $result.providerReads | Should -Be 0
            $result.providerWrites | Should -Be 0
            $c.state.calls.Count | Should -Be 0
            Test-Path $c.root | Should -BeFalse
        }
        It 'evaluates the exact generation syntactically and leaves Owner unknown' {
            $c = Get-SignedIntakeCase
            [void](Invoke-SignedIntakeCase $c)
            $c.state.calls.Clear()
            $result = Invoke-RunnerCase $c
            $result.state | Should -Be 'candidate-only-read-only'
            $result.selected | Should -Be 2
            $result.draft | Should -Be 1
            $result.skipped | Should -Be 1
            $result.pending | Should -Be 0
            $result.providerWrites | Should -Be 0
            $result.modelToolInvocations | Should -Be 0
            $result.writerEligible | Should -BeFalse
            $result.rules[0].unknown | Should -Be 2
            @($result.rules | Select-Object -Skip 1 |
                Where-Object evaluated -NE 2).Count | Should -Be 0
            @($c.state.calls | Where-Object {
                    $_ -notin @('Identity', 'Head', 'Changes', 'Discussions')
                }).Count | Should -Be 0
            @($c.state.calls | Where-Object { $_ -eq 'Discussions' }).Count |
                Should -Be 4
            ($result | ConvertTo-Json -Depth 16) |
                Should -Not -Match 'signature|synthetic|service@example.invalid'
        }
        It 'binds the distinct coverage candidates to complete changed C# graph evidence' {
            $c = Get-SignedIntakeCase -Code
            [void](Invoke-SignedIntakeCase $c)
            $result = Invoke-RunnerCase $c
            $result.rules[0].unknown | Should -Be 2
            $result.rules[1].evaluated | Should -Be 2
            $result.rules[1].wouldCreate | Should -Be 2
            $result.rules[2].evaluated | Should -Be 2
            $result.rules[3].evaluated | Should -Be 2
            $result.providerWrites | Should -Be 0
            $result.writerEligible | Should -BeFalse
        }
        It 'rejects forged signature, receipt, generation, head, commit and graph' {
            foreach ($failure in @('signature', 'receipt', 'generation',
                    'config', 'head', 'commit', 'graph', 'principal')) {
                $c = Get-SignedIntakeCase
                [void](Invoke-SignedIntakeCase $c)
                $c.state.calls.Clear()
                switch ($failure) {
                    signature {
                        Set-RunnerFile $c 'canary-dispatcher.json' {
                            param($value)
                            $value.rules[1].declarationDigest = 'v1:sha256:' + 'f' * 64
                        }
                    }
                    receipt {
                        Set-RunnerFile $c 'approved-sources.json' {
                            param($value)
                            $value.rules['bpm-test-class-coverage@2'].blobId = 'f' * 40
                        }
                    }
                    generation {
                        $path = Join-Path $c.root 'active-pr-intake-v1\cohort.json'
                        $value = Get-Content $path -Raw |
                            ConvertFrom-Json -AsHashtable -Depth 32
                        $value.inventory.draft = 0
                        [IO.File]::WriteAllText($path, (ConvertTo-Json $value -Depth 32))
                    }
                    config {
                        Sign-RunnerConfig $c {
                            param($value)
                            $value.heads[0].sourceCommit = 'f' * 40
                        }
                    }
                    head { $c.state.wrong = 'stale-head' }
                    commit { $c.input.case.state.wrong = 'commit' }
                    graph { $c.state.wrong = 'fake-graph' }
                    principal { $c.input.case.state.wrong = 'principal' }
                }
                { Invoke-RunnerCase $c } | Should -Throw -Because $failure
                @($c.state.calls | Where-Object {
                        $_ -notin @('Identity', 'Head', 'Changes', 'Discussions')
                    }).Count | Should -Be 0
            }
        }
        It 'rejects altered source blob and mixed project ownership after signing' {
            foreach ($failure in @('blob-content', 'mixed-project')) {
                $c = Get-SignedIntakeCase -Code
                [void](Invoke-SignedIntakeCase $c)
                $c.state.wrong = $failure
                { Invoke-RunnerCase $c } | Should -Throw -Because $failure
                @($c.state.calls | Where-Object {
                        $_ -notin @('Identity', 'ListPage', 'Head',
                            'Changes', 'Discussions')
                    }).Count | Should -Be 0
            }
        }
        It 'counts same-account unmarked comments as human, not automation' {
                $c = Get-SignedIntakeCase -Code
                [void](Invoke-SignedIntakeCase $c)
                $c.state.threads = @(New-RunnerThread $c 1 'Exclude from code coverage.')
                $result = Invoke-RunnerCase $c
                $result.rules[1].humanCovered | Should -Be 2
                $result.rules[1].wouldCreate | Should -Be 0
                $result.providerWrites | Should -Be 0
            }
        It 'treats duplicate nearby comments and concurrent discussion edits as unknown' {
                $c = Get-SignedIntakeCase -Code
                [void](Invoke-SignedIntakeCase $c)
                $c.state.threads = @(
                    (New-RunnerThread $c 1 'Exclude from code coverage.'),
                    (New-RunnerThread $c 2 'Exclude from code coverage.')
                )
                $ambiguous = Invoke-RunnerCase $c
                $ambiguous.rules[1].unknown | Should -Be 2
                $ambiguous.rules[1].humanCovered | Should -Be 0
                $ambiguous.rules[1].wouldCreate | Should -Be 0
                $c.state.threads = @(New-RunnerThread $c 1 'Exclude from code coverage.')
                $c.state.discussionVisits = 0
                $c.state.wrong = 'discussion-drift'
                { Invoke-RunnerCase $c } | Should -Throw '*canary-discussion-drift*'
        }
        It 'keeps colliding exact current-generation reviewer markers unknown' {
            $c = Get-SignedIntakeCase -Code
            [void](Invoke-SignedIntakeCase $c)
            $body = Get-RunnerClassMarkerBody $c
            $body | Should -Match 'unmerged candidate-only convention'
            $body | Should -Not -Match 'User-approved convention'
            $c.state.threads = @(New-RunnerThread $c 1 $body)
            $single = Invoke-RunnerCase $c
            $single.heads[0].rules[1].status | Should -Be 'evaluated'
            $single.heads[0].rules[1].wouldCreate | Should -Be 0
            $c.state.threads = @(
                (New-RunnerThread $c 1 $body),
                (New-RunnerThread $c 2 $body)
            )
            $result = Invoke-RunnerCase $c
            $result.rules[1].evaluated | Should -Be 0
            $result.rules[1].unknown | Should -Be 2
            $result.rules[1].wouldCreate | Should -Be 0
            $result.providerWrites | Should -Be 0
        }
        It 'does not count an outdated marker as current coverage' {
            $c = Get-SignedIntakeCase -Code
            [void](Invoke-SignedIntakeCase $c)
            $body = Get-RunnerClassMarkerBody $c
            $c.state.threads = @(New-RunnerThread $c 1 $body -Outdated)
            $result = Invoke-RunnerCase $c
            $result.heads[0].rules[1].status | Should -Be 'unknown'
            $result.heads[0].rules[1].wouldCreate | Should -Be 0
            $result.providerWrites | Should -Be 0
        }
        It 'rejects state under or containing the repository before contacting ADO' {
            $c = Get-SignedIntakeCase
            { Invoke-PrivateCanaryEvaluation -StateRoot $repo `
                    -RepositoryRoot $repo -Read $c.read -Provider $c.provider -Run } |
                Should -Throw '*external*'
            $c.state.calls.Count | Should -Be 0
        }
        It 'rejects a formerly private input with newly permissive ACL before reads' {
            $c = Get-SignedIntakeCase
            [void](Invoke-SignedIntakeCase $c)
            $c.state.calls.Clear()
            $file = Join-Path $c.root 'canary-dispatcher.json'
            if ($IsWindows) {
                $acl = Get-Acl -LiteralPath $file
                $everyone = [Security.Principal.SecurityIdentifier]::new(
                    [Security.Principal.WellKnownSidType]::WorldSid, $null)
                $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
                        $everyone, [Security.AccessControl.FileSystemRights]::Read,
                        [Security.AccessControl.AccessControlType]::Allow))
                Set-Acl -LiteralPath $file -AclObject $acl
            } else {
                [IO.File]::SetUnixFileMode($file,
                    ([IO.File]::GetUnixFileMode($file) -bor
                        [IO.UnixFileMode]::OtherRead))
            }
            { Invoke-RunnerCase $c } | Should -Throw
            $c.state.calls.Count | Should -Be 0
        }
    }
    It 'defaults off with zero reads, writes, or private state' {
        $c = Get-BootstrapCase
        $result = Invoke-PrivateCanaryBootstrap -Organization 'example-org' `
            -ProjectName 'ExampleProject' -RepositoryName 'ExampleRepo' `
            -ExpectedAccountUniqueName 'service@example.invalid' `
            -StateRoot $c.root -RepositoryRoot $repo -Read $c.provider
        $result.state | Should -Be 'disabled'
        $result.signed | Should -BeFalse
        $c.state.reads.Count | Should -Be 0
        Test-Path $c.root | Should -BeFalse
    }
    Describe 'Four-source read-only registry from verified receipts' {
        It 'defaults off without consuming even a malformed receipt or contacting ADO' {
            $c = Get-BootstrapCase
            $result = New-VerifiedCanaryRuleRegistry -ProviderConfig @{} `
                -ApprovedSources @{} -RepositoryRoot $repo -Read $c.provider
            $result.state | Should -Be 'disabled'
            $result.providerWrites | Should -Be 0
            $c.state.reads.Count | Should -Be 0
            Test-Path $c.root | Should -BeFalse
        }
        Describe 'Signed four-source intake handoff without evaluation' {
            It 'defaults off with no source reads, state, signing, or model' {
                $c = Get-SignedIntakeCase
                $c.input.case.state.reads.Clear()
                $result = Invoke-PrivateCanarySignedIntake -ProviderConfig @{} `
                    -ApprovedSources @{} -StateRoot $c.root -RepositoryRoot $repo `
                    -CanaryPullRequestIds @(17007699, 17109075) `
                    -Read $c.input.case.provider -Provider $c.provider
                $result.state | Should -Be 'disabled'
                $result.providerReads | Should -Be 0
                $result.modelToolInvocations | Should -Be 0
                $c.state.calls.Count | Should -Be 0
                $c.input.case.state.reads.Count | Should -Be 0
                Test-Path $c.root | Should -BeFalse
                $json = & (Join-Path $repo 'tools\Invoke-PrivateCanarySignedIntake.ps1') `
                    -ProviderConfigPath (Join-Path $c.input.case.root 'provider-config.json') `
                    -ApprovedSourcesPath (Join-Path $c.input.case.root 'approved-sources.json') `
                    -StateRoot $c.root -CanaryPullRequestIds @(17007699, 17109075)
                ($json | ConvertFrom-Json -AsHashtable).state | Should -Be 'disabled'
                Test-Path $c.root | Should -BeFalse
            }
            It 'signs only a complete two-pass cohort and leaves all four rules disabled' {
                $c = Get-SignedIntakeCase
                $result = Invoke-SignedIntakeCase $c
                $result.state | Should -Be 'signed-intake-not-evaluated'
                $result.signed | Should -BeTrue
                $result.evaluated | Should -BeFalse
                $result.writerEligible | Should -BeFalse
                $result.providerWrites | Should -Be 0
                $result.modelToolInvocations | Should -Be 0
                $result.inventory.active | Should -Be 4
                $result.inventory.nonDraft | Should -Be 3
                $result.inventory.draft | Should -Be 1
                $result.inventory.eligible | Should -Be 2
                $result.selected | Should -Be 2
                $result.pending | Should -Be 2
                $result.skipped | Should -Be 1
                @($result.rules | Where-Object {
                        $_.evaluated -ne 0 -or $_.wouldCreate -ne 0
                    }).Count | Should -Be 0
                $config = Get-Content -LiteralPath (
                    Join-Path $c.root 'canary-dispatcher.json') -Raw |
                    ConvertFrom-Json -AsHashtable
                $key = Get-Content -LiteralPath (
                    Join-Path $c.root 'signature.key') -Raw
                $signed = $config.signature
                $config.Remove('signature')
                $hmac = [Security.Cryptography.HMACSHA256]::new(
                    [Text.Encoding]::UTF8.GetBytes($key))
                try {
                    $expected = 'v1:hmac-sha256:' +
                        [Convert]::ToHexString($hmac.ComputeHash(
                                [Text.Encoding]::UTF8.GetBytes(
                                    (ConvertTo-AgentCanonicalJson -InputObject $config))
                            )).ToLowerInvariant()
                    $signed | Should -Be $expected
                }
                finally { $hmac.Dispose() }
                $config.rules.Count | Should -Be 4
                $config.rules[1].declarationDigest |
                    Should -Not -Be $config.rules[2].declarationDigest
                @($config.rules | Where-Object {
                        $_.enabled -or $_.evaluated -or $_.writerEligible
                    }).Count | Should -Be 0
                @($c.state.calls | Where-Object {
                        $_ -notin @('Identity', 'ListPage', 'Head', 'Changes',
                            'Discussions')
                    }).Count | Should -Be 0
                @($c.input.case.state.reads | Where-Object {
                        $_ -in @('Post', 'Write', 'ListPage', 'Changes')
                    }).Count | Should -Be 0
                ($result | ConvertTo-Json -Depth 10) | Should -Not -Match `
                    'synthetic|signature|service@example.invalid'
                foreach ($name in @('signature.key', 'provider-config.json',
                        'approved-sources.json', 'canary-intake.json',
                        'canary-dispatcher.json')) {
                    [void](Assert-AgentTrustedFile -Path (Join-Path $c.root $name) `
                            -AllowedRoot $c.root -Private)
                }
            }
            It 'refuses split inventory, stale heads, fake graph and forged receipt before signing' {
                foreach ($failure in @('split-page', 'stale-head', 'fake-graph',
                        'forged-receipt', 'cursor-collision', 'late-head',
                        'provider-drift')) {
                    $c = Get-SignedIntakeCase
                    if ($failure -eq 'forged-receipt') {
                        $c.input.sources.rules['bpm-redundant-method-coverage@2'].blobId =
                            'f' * 40
                    } elseif ($failure -eq 'cursor-collision') {
                        $c.state.rows = @($c.state.rows) + @(
                            for ($n = 0; $n -lt 48; $n++) {
                                @{ pullRequestId = 17110000 + $n
                                    status = 'active'; isDraft = $true
                                    targetRef = 'refs/heads/master'
                                    creationDate = [DateTime]::UtcNow.AddMinutes(
                                        -20 - $n).ToString('o') }
                            }
                        )
                        $c.state.rows[50].creationDate =
                            $c.state.rows[49].creationDate
                    } else { $c.state.wrong = $failure }
                    { Invoke-SignedIntakeCase $c } | Should -Throw -Because $failure
                    Test-Path (Join-Path $c.root 'signature.key') | Should -BeFalse
                    @($c.state.calls | Where-Object {
                            $_ -notin @('Identity', 'ListPage', 'Head', 'Changes',
                                'Discussions')
                        }).Count | Should -Be 0
                }
            }
            It 'rejects cross-volume aliases without treating an external path as repository state' {
                if (-not $IsWindows) { Set-ItResult -Skipped -Because 'Windows drives only' }
                else {
                    (Test-AgentPathWithin -Path 'Z:\synthetic\private-state' `
                        -Root $repo) | Should -BeFalse
                    (Test-AgentPathWithin -Path $repo `
                        -Root 'Z:\synthetic\private-state') | Should -BeFalse
                }
            }
            It 'rejects a preexisting or repository-ancestor state root without reading' {
                $c = Get-SignedIntakeCase
                $c.root = $repo
                { Invoke-SignedIntakeCase $c } | Should -Throw '*state-root-must-be-external*'
                $c.state.calls.Count | Should -Be 0
                $c.root = $c.input.case.root
                { Invoke-SignedIntakeCase $c } | Should -Throw '*must-be-new*'
                $c.state.calls.Count | Should -Be 0
            }
        }
        It 'keeps the repository command disabled with actual trusted bootstrap files' {
            $inputCase = Get-RegistryCase
            $json = & (Join-Path $repo 'tools\Invoke-PrivateCanaryRuleRegistry.ps1') `
                -ProviderConfigPath (Join-Path $inputCase.case.root 'provider-config.json') `
                -ApprovedSourcesPath (Join-Path $inputCase.case.root 'approved-sources.json')
            $result = $json | ConvertFrom-Json -AsHashtable
            $result.state | Should -Be 'disabled'
            $result.providerReads | Should -Be 0
            $result.providerWrites | Should -Be 0
        }
        It 'rechecks both immutable documents and head and binds four disabled distinct sources' {
            $inputCase = Get-RegistryCase
            $result = Invoke-RegistryCase $inputCase
            $result.state | Should -Be 'verified-not-evaluated'
            $result.evaluated | Should -BeFalse
            $result.writerEligible | Should -BeFalse
            $result.providerWrites | Should -Be 0
            $result.providerReads | Should -Be 17
            $result.rules.Count | Should -Be 4
            $result.rules['bpm-test-ownership@1'].sourceAuthority |
                Should -Be 'pinned-owner-section'
            $result.rules['bpm-test-class-coverage@2'].sourceAuthority |
                Should -Be 'verified-unmerged-candidate-only'
            $result.rules['bpm-test-class-coverage@2'].declarationDigest |
                Should -Not -Be $result.rules['bpm-redundant-method-coverage@2'].declarationDigest
            $result.rules['bpm-named-areequal-arguments@1'].sourceAuthority |
                Should -Be 'repository-local-commit'
            @($result.rules.Values | Where-Object { $_.enabled -or $_.evaluated -or
                    $_.writerEligible }).Count | Should -Be 0
            @($inputCase.case.state.reads | Where-Object {
                    $_ -in @('ListPage', 'Head', 'Changes', 'Discussions',
                        'Write', 'Post') }).Count | Should -Be 0
            ($result | ConvertTo-Json -Depth 10) | Should -Not -Match 'Synthetic convention'
            $inputCase.sources.rules['bpm-test-ownership@1'].sectionHash |
                Should -Not -Be $inputCase.sources.namedSection.sectionHash
        }
        It 'rejects wrong or missing receipts and independently mutated Owner and Named pins' {
            foreach ($failure in @('schema', 'missing', 'owner', 'owner-length',
                    'named-section', 'named-blob', 'class', 'redundant',
                    'class-head', 'named-policy', 'named-digest', 'repository',
                    'project')) {
                $inputCase = Get-RegistryCase
                switch ($failure) {
                    schema { $inputCase.sources.schemaVersion = 1 }
                    missing {
                        $inputCase.sources.rules.Remove('bpm-test-class-coverage@2')
                    }
                    owner {
                        $inputCase.sources.rules['bpm-test-ownership@1'].sectionHash =
                            'v1:sha256:' + ('a' * 64)
                    }
                    'owner-length' {
                        $inputCase.sources.rules['bpm-test-ownership@1'].sectionLength++
                    }
                    'named-section' {
                        $inputCase.sources.namedSection.sectionHash =
                            'v1:sha256:' + ('a' * 64)
                    }
                    'named-blob' { $inputCase.sources.namedSection.blobId = 'a' * 40 }
                    class {
                        $inputCase.sources.rules['bpm-test-class-coverage@2'].policyLineHash =
                            'v1:sha256:' + ('a' * 64)
                    }
                    redundant {
                        $inputCase.sources.rules['bpm-redundant-method-coverage@2'].declarationDigest =
                            'v1:sha256:' + ('a' * 64)
                    }
                    'class-head' {
                        $inputCase.sources.rules['bpm-test-class-coverage@2'].headVerified =
                            $false
                    }
                    'named-policy' {
                        $inputCase.sources.rules['bpm-named-areequal-arguments@1'].policyHash =
                            'v1:sha256:' + ('a' * 64)
                    }
                    'named-digest' {
                        $inputCase.sources.rules['bpm-named-areequal-arguments@1'].declarationDigest =
                            'v1:sha256:' + ('a' * 64)
                    }
                    repository {
                        $inputCase.config.repository.id =
                            'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
                    }
                    project {
                        $inputCase.config.projectId =
                            'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
                    }
                }
                { Invoke-RegistryCase $inputCase } | Should -Throw -Because $failure
                @($inputCase.case.state.reads | Where-Object {
                        $_ -in @('Write', 'Post', 'Changes', 'ListPage')
                    }).Count | Should -Be 0
            }
        }
        It 'fails on a changed current PR head, source blob, or principal after preparation' {
            foreach ($failure in @('head', 'head-after', 'blob',
                    'principal-final')) {
                $inputCase = Get-RegistryCase
                switch ($failure) {
                    head { $inputCase.case.state.head = 'a' * 40 }
                    'head-after' {
                        $inputCase.case.state.headChecks = 0
                        $inputCase.case.state.wrong = 'head-drift'
                    }
                    blob { $inputCase.case.state.wrong = 'blob' }
                    'principal-final' {
                        $inputCase.case.state.wrong = 'principal-final'
                    }
                }
                { Invoke-RegistryCase $inputCase } | Should -Throw -Because $failure
                @($inputCase.case.state.reads | Where-Object {
                        $_ -in @('Write', 'Post', 'Changes', 'ListPage')
                    }).Count | Should -Be 0
            }
        }
    }
    It 'derives private provider identity and four distinct candidate/local source bindings' {
        $c = Get-BootstrapCase
        $result = Invoke-BootstrapCase $c
        $result.state | Should -Be 'prepared-read-only'
        $result.signed | Should -BeFalse
        $result.canaryExecuted | Should -BeFalse
        $result.providerWrites | Should -Be 0
        $result.ruleCount | Should -Be 4
        $c.state.reads.Count | Should -BeLessOrEqual 20
        $c.state.reads[-1] | Should -Be 'Identity'
        @($c.state.reads | Where-Object { $_ -in @('ListPage', 'Head', 'Changes',
                    'Discussions', 'Write', 'Post') }).Count | Should -Be 0
        $config = Get-Content (Join-Path $c.root 'provider-config.json') -Raw |
            ConvertFrom-Json -AsHashtable
        $manifest = Get-Content (Join-Path $c.root 'approved-sources.json') -Raw |
            ConvertFrom-Json -AsHashtable
        $config.projectId | Should -Be '22222222-2222-2222-2222-222222222222'
        $config.repository.id | Should -Be '11111111-1111-1111-1111-111111111111'
        $config.expectedAccount.descriptor | Should -Be 'aad.synthetic'
        $manifest.rules.Count | Should -Be 4
        $manifest.namedSection.commit | Should -Be $manifest.rules['bpm-test-ownership@1'].commit
        $manifest.rules['bpm-test-class-coverage@2'].headVerified | Should -BeTrue
        $manifest.rules['bpm-test-class-coverage@2'].declarationDigest |
            Should -Not -Be $manifest.rules['bpm-redundant-method-coverage@2'].declarationDigest
        $manifest.rules['bpm-named-areequal-arguments@1'].provenance |
            Should -Be 'repository-local-commit'
        @($manifest.rules.Values | Where-Object {
                [string]$_.declarationDigest -cnotmatch '^v1:sha256:[a-f0-9]{64}$'
            }).Count | Should -Be 0
        $manifest.rules['bpm-test-ownership@1'].blobId |
            Should -Match '^[a-f0-9]{40}$'
        $manifest.rules['bpm-test-class-coverage@2'].blobId |
            Should -Match '^[a-f0-9]{40}$'
        $manifest.rules['bpm-named-areequal-arguments@1'].repositoryId |
            Should -BeNullOrEmpty
        Test-Path (Join-Path $c.root 'signature.key') | Should -BeFalse
        [void](Assert-AgentTrustedFile -Path (
                Join-Path $c.root 'approved-sources.json') -Private)
    }
    It 'rejects stale PR head, wrong metadata, commit, blob and partial inputs before writing' {
        foreach ($failure in @('head', 'head-drift', 'project', 'repository',
                'principal', 'commit', 'blob', 'source-path',
                'partial', 'principal-final', 'named')) {
            $c = Get-BootstrapCase
            switch ($failure) {
                head { $c.state.head = 'a' * 40 }
                'head-drift' { $c.state.wrong = 'head-drift' }
                named { $c.state.owner = $c.state.owner.Replace(
                        'Synthetic named rule.', 'Tampered named rule.') }
                default { $c.state.wrong = $failure }
            }
            { Invoke-BootstrapCase $c } | Should -Throw -Because $failure
            Test-Path $c.root | Should -BeFalse
            @($c.state.reads | Where-Object {
                    $_ -in @('Write', 'Post', 'Changes', 'ListPage')
                }).Count | Should -Be 0
        }
    }
    It 'rejects malicious input and refuses a preexisting, contained, or untrusted state root' {
        $c = Get-BootstrapCase
        { Invoke-PrivateCanaryBootstrap -Organization 'example-org/path' `
                -ProjectName 'ExampleProject' -RepositoryName 'ExampleRepo' `
                -ExpectedAccountUniqueName 'service@example.invalid' `
                -StateRoot $c.root -RepositoryRoot $repo -Read $c.provider -Run } |
            Should -Throw '*bootstrap-input-invalid*'
        $c.state.reads.Count | Should -Be 0
        New-Item -ItemType Directory $c.root | Out-Null
        { Invoke-BootstrapCase $c } | Should -Throw '*must-be-new*'
        $c.state.reads.Count | Should -Be 0
        $c.root = Join-Path $repo 'private-state'
        { Invoke-BootstrapCase $c } | Should -Throw '*bootstrap-input-invalid*'
        $c.state.reads.Count | Should -Be 0
    }
    It 'refuses a local policy that differs from its repository commit instead of treating it as remote' {
        $c = Get-BootstrapCase
        Mock Get-CanaryGitValue -ModuleName DevPilot.ActivePrCanary {
            '0' * 40
        } -ParameterFilter { $Arguments[0] -eq 'hash-object' }
        { Invoke-BootstrapCase $c } | Should -Throw '*local-rule-source-unavailable*'
        Test-Path $c.root | Should -BeFalse
        @($c.state.reads | Where-Object { $_ -in @('Write', 'Post') }).Count |
            Should -Be 0
    }
    It 'sends only bounded GETs to fixed ADO routes with one bearer and no token in URL' {
        $handler = [CanarySyntheticHandler]::new()
        $client = [Net.Http.HttpClient]::new($handler)
        $module = Get-Module DevPilot.ActivePrCanary
        try {
            $read = {
                param($Op, $ReadRequest)
                & $module {
                    param($Client, $Op, $ReadRequest)
                    Invoke-CanaryAadGet $Client 'synthetic-bearer' 'example-org' `
                        $Op $ReadRequest ([DateTime]::UtcNow.AddSeconds(5))
                } $client $Op $ReadRequest
            }
            (& $read Project @{ projectName = 'ExampleProject' }).id |
                Should -Be 'synthetic'
            (& $read Identity @{}).descriptor | Should -Be 'aad.synthetic'
            $request = @{ projectName = 'Engineering'
                repositoryId = '44444444-4444-4444-4444-444444444444'
                commit = '7e6620ec40c9bc37c5a5e13d506053b0139c9206'
                path = '/documentation/EngineeringProcesses/Conventions/AutomatedTests.md' }
            (& $read Item $request).id | Should -Be 'synthetic'
            [Text.Encoding]::UTF8.GetString((& $read RawItem $request).bytes) |
                Should -Be 'synthetic bytes'
            $handler.Paths.Count | Should -Be 4
            @($handler.Paths | Where-Object {
                    $_ -notlike 'https://dev.azure.com/example-org/*' -or
                    $_ -match 'synthetic-bearer'
                }).Count | Should -Be 0
            $handler.Paths[3] | Should -Match 'versionDescriptor.versionType=commit'
            { & $read Project @{ projectName = '..' } } | Should -Throw
            $malicious = $request.Clone()
            $malicious.commit = 'malicious'
            { & $read Item $malicious } | Should -Throw
            $handler.Paths.Count | Should -Be 4
        }
        finally { $client.Dispose() }
    }
    It 'reports only the operation and HTTP status when a bounded source GET fails' {
        $handler = [CanarySyntheticHandler]::new()
        $handler.Status = [Net.HttpStatusCode]::Redirect
        $client = [Net.Http.HttpClient]::new($handler)
        $module = Get-Module DevPilot.ActivePrCanary
        $c = Get-BootstrapCase
        $state = $c.state
        $c.provider = {
            param($operation, $request)
            $state.reads.Add($operation) | Out-Null
            & $module {
                param($Client, $Operation, $Request)
                Invoke-CanaryAadGet $Client 'synthetic-bearer' 'example-org' `
                    $Operation $Request ([DateTime]::UtcNow.AddSeconds(5))
            } $client $operation $request
        }.GetNewClosure()
        try {
            $message = try {
                Invoke-BootstrapCase $c
                ''
            }
            catch { $_.Exception.Message }
            $message | Should -Be 'bootstrap-read-inaccessible:Identity:http-302'
            Test-Path $c.root | Should -BeFalse
            $state.reads.Count | Should -Be 1
            $state.reads[0] | Should -Be 'Identity'
            $handler.Paths.Count | Should -Be 1
        }
        finally { $client.Dispose() }
    }
    It 'redacts transport failures before any state creation or provider write' {
        $handler = [CanarySyntheticHandler]::new()
        $handler.FailTransport = $true
        $client = [Net.Http.HttpClient]::new($handler)
        $module = Get-Module DevPilot.ActivePrCanary
        $c = Get-BootstrapCase
        $state = $c.state
        $c.provider = {
            param($operation, $request)
            $state.reads.Add($operation) | Out-Null
            & $module {
                param($Client, $Operation, $Request)
                Invoke-CanaryAadGet $Client 'synthetic-bearer' 'example-org' `
                    $Operation $Request ([DateTime]::UtcNow.AddSeconds(5))
            } $client $operation $request
        }.GetNewClosure()
        try {
            $message = try {
                Invoke-BootstrapCase $c
                ''
            }
            catch { $_.Exception.Message }
            $message | Should -Be 'bootstrap-read-inaccessible:Identity:send'
            Test-Path $c.root | Should -BeFalse
            $state.reads.Count | Should -Be 1
            $state.reads[0] | Should -Be 'Identity'
            $handler.Paths.Count | Should -Be 1
        }
        finally { $client.Dispose() }
    }
    It 'redacts bounded response read and decode failures without private state' {
        foreach ($case in @(
                @{ phase = 'read'; oversize = $true; invalidJson = $false },
                @{ phase = 'decode'; oversize = $false; invalidJson = $true })) {
            $handler = [CanarySyntheticHandler]::new()
            $handler.Oversize = $case.oversize
            $handler.InvalidJson = $case.invalidJson
            $client = [Net.Http.HttpClient]::new($handler)
            $module = Get-Module DevPilot.ActivePrCanary
            $c = Get-BootstrapCase
            $state = $c.state
            $c.provider = {
                param($operation, $request)
                $state.reads.Add($operation) | Out-Null
                & $module {
                    param($Client, $Operation, $Request)
                    Invoke-CanaryAadGet $Client 'synthetic-bearer' 'example-org' `
                        $Operation $Request ([DateTime]::UtcNow.AddSeconds(5))
                } $client $operation $request
            }.GetNewClosure()
            try {
                $message = try {
                    Invoke-BootstrapCase $c
                    ''
                }
                catch { $_.Exception.Message }
                $message | Should -Be "bootstrap-read-inaccessible:Identity:$($case.phase)"
                Test-Path $c.root | Should -BeFalse
                $state.reads.Count | Should -Be 1
                $state.reads[0] | Should -Be 'Identity'
                $handler.Paths.Count | Should -Be 1
            }
            finally { $client.Dispose() }
        }
    }
}
