#requires -Version 7.0
BeforeAll {
    $repo = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $repo 'src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1')
    Import-Module (Join-Path $repo 'src\DevPilot.ActivePrCanary\DevPilot.ActivePrCanary.psm1') -Force
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
    protected override Task<HttpResponseMessage> SendAsync(
        HttpRequestMessage request, CancellationToken cancellationToken) {
        if (request.Method != HttpMethod.Get ||
            request.Headers.Authorization?.Scheme != "Bearer" ||
            request.Headers.Authorization?.Parameter != "synthetic-bearer" ||
            request.RequestUri.Host != "dev.azure.com") {
            throw new InvalidOperationException("unbound synthetic GET");
        }
        Paths.Add(request.RequestUri.AbsoluteUri);
        var content = request.RequestUri.AbsolutePath.EndsWith("/connectionData")
            ? Encoding.UTF8.GetBytes("{\"authenticatedUser\":{\"id\":\"33333333-3333-3333-3333-333333333333\",\"subjectDescriptor\":\"aad.synthetic\",\"uniqueName\":\"service@example.invalid\"}}")
            : request.Headers.Accept.ToString() == "application/octet-stream"
            ? Encoding.UTF8.GetBytes("synthetic bytes")
            : Encoding.UTF8.GetBytes("{\"id\":\"synthetic\"}");
        return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) {
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
}
