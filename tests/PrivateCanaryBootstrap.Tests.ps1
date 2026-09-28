#requires -Version 7.0
BeforeAll {
    $repo = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $repo 'src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1')
    Import-Module (Join-Path $repo 'src\OwnerObservationContract\OwnerObservationContract.psd1')
    Import-Module (Join-Path $repo 'src\DevPilot.OwnerAdapters\DevPilot.OwnerAdapters.psd1')
    Import-Module (Join-Path $repo 'src\DevPilot.OwnerCapability\DevPilot.OwnerCapability.psd1')
    Import-Module (Join-Path $repo 'src\DevPilot.ActivePrIntake\DevPilot.ActivePrIntake.psd1')
    Import-Module (Join-Path $repo 'src\DevPilot.ActivePrCanary\DevPilot.ActivePrCanary.psm1') -Force
    Import-Module (Join-Path $repo 'src\DevPilot.ActivePrCanary\DevPilot.PrivateCanaryRunner.psd1') -Force
    . (Join-Path $repo 'src\DevPilot.ActivePrCanary\PrivateCanaryIdentityOutput.ps1')
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
    public bool ThrottleHint = false;
    public string BudgetRemaining;
    public byte[] Body;
    public byte[] GraphUserBody;
    public byte[] StorageKeyBody;
    public string MediaType;
    public string ContentEncoding;
    public HttpStatusCode GraphUserStatus = HttpStatusCode.OK;
    public HttpStatusCode StorageKeyStatus = HttpStatusCode.OK;
    protected override Task<HttpResponseMessage> SendAsync(
        HttpRequestMessage request, CancellationToken cancellationToken) {
        if (request.Method != HttpMethod.Get ||
            request.Headers.Authorization?.Scheme != "Bearer" ||
            request.Headers.Authorization?.Parameter != "synthetic-bearer" ||
            (request.RequestUri.Host != "dev.azure.com" &&
             (request.RequestUri.Host != "vssps.dev.azure.com" ||
              (request.RequestUri.AbsolutePath != "/example-org/_apis/graph/users/aad.synthetic" &&
               request.RequestUri.AbsolutePath != "/example-org/_apis/graph/storagekeys/aad.synthetic")))) {
            throw new InvalidOperationException("unbound synthetic GET");
        }
        Paths.Add(request.RequestUri.AbsoluteUri);
        if (FailTransport) {
            throw new HttpRequestException("private transport detail");
        }
        var isUser = request.RequestUri.AbsolutePath.Contains("/_apis/graph/users/");
        var isStorage = request.RequestUri.AbsolutePath.Contains("/_apis/graph/storagekeys/");
        var content = isUser
            ? GraphUserBody ?? Encoding.UTF8.GetBytes("{\"descriptor\":\"aad.synthetic\",\"subjectKind\":\"user\",\"principalName\":\"service@example.invalid\"}")
            : isStorage
            ? StorageKeyBody ?? Encoding.UTF8.GetBytes("{\"value\":\"33333333-3333-3333-3333-333333333333\"}")
            : request.RequestUri.AbsolutePath.EndsWith("/connectionData")
            ? Encoding.UTF8.GetBytes("{\"authenticatedUser\":{\"id\":\"33333333-3333-3333-3333-333333333333\",\"subjectDescriptor\":\"aad.synthetic\",\"uniqueName\":\"service@example.invalid\"}}")
            : request.Headers.Accept.ToString() == "application/octet-stream"
            ? Encoding.UTF8.GetBytes("synthetic bytes")
            : Encoding.UTF8.GetBytes("{\"id\":\"synthetic\"}");
        if (Oversize) content = new byte[65537];
        if (InvalidJson) content = Encoding.UTF8.GetBytes("{");
        var response = new HttpResponseMessage(isUser ? GraphUserStatus :
            isStorage ? StorageKeyStatus : Status) {
            Content = new ByteArrayContent(isUser || isStorage
                ? content : Body ?? content)
        };
        if (MediaType != null) {
            response.Content.Headers.ContentType =
                new System.Net.Http.Headers.MediaTypeHeaderValue(MediaType);
        }
        if (ContentEncoding != null) {
            response.Content.Headers.ContentEncoding.Add(ContentEncoding);
        }
        if (ThrottleHint) {
            response.Headers.RetryAfter =
                new System.Net.Http.Headers.RetryConditionHeaderValue(
                    TimeSpan.FromSeconds(1));
        }
        if (BudgetRemaining != null) {
            response.Headers.Add("x-ms-ratelimit-remaining-resource",
                BudgetRemaining);
        }
        return Task.FromResult(response);
    }
}
'@
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Net;
using System.Net.Http;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
public sealed class CanaryBoundGetHandler : HttpMessageHandler {
    public List<string> Paths = new List<string>();
    public List<string> Tokens = new List<string>();
    public bool OmitUniqueName = false;
    public bool DriftStorageKey = false;
    public bool ThrottleInventory = false;
    public bool TooLarge = false;
    public bool DriftRef = false;
    public bool GraphEnabled = false;
    public bool CorruptTree = false;
    public bool MissingProject = false;
    public bool ThrottleTree = false;
    public bool IncompleteChanges = false;
    public string SourceFile;
    public string ProjectFile;
    public string SourceObjectId;
    public string ProjectObjectId;
    public string RootTreeId;
    public string TestsTreeId;
    protected override Task<HttpResponseMessage> SendAsync(
        HttpRequestMessage request, CancellationToken cancellationToken) {
        if (request.Method != HttpMethod.Get ||
            request.Headers.Authorization?.Scheme != "Bearer") {
            throw new InvalidOperationException("unexpected or writing HTTP operation");
        }
        Paths.Add(request.RequestUri.AbsoluteUri);
        Tokens.Add(request.Headers.Authorization?.Parameter ?? "");
        var path = request.RequestUri.AbsolutePath;
        string body;
        if (path.EndsWith("/connectionData")) {
            body = "{\"authenticatedUser\":{\"id\":\"33333333-3333-3333-3333-333333333333\",\"subjectDescriptor\":\"aad.synthetic\"" +
                (OmitUniqueName ? "" : ",\"uniqueName\":\"service@example.invalid\"") + "}}";
        } else if (path.EndsWith("/graph/users/aad.synthetic")) {
            body = "{\"descriptor\":\"aad.synthetic\",\"subjectKind\":\"user\",\"principalName\":\"service@example.invalid\"}";
        } else if (path.EndsWith("/graph/storagekeys/aad.synthetic")) {
            body = "{\"value\":\"" + (DriftStorageKey
                ? "44444444-4444-4444-4444-444444444444"
                : "33333333-3333-3333-3333-333333333333") + "\"}";
        } else if (path.EndsWith("/_apis/projects/ExampleProject")) {
            body = "{\"id\":\"22222222-2222-2222-2222-222222222222\",\"name\":\"ExampleProject\"}";
        } else if (path.EndsWith("/_apis/git/repositories/11111111-1111-1111-1111-111111111111")) {
            body = "{\"id\":\"11111111-1111-1111-1111-111111111111\",\"name\":\"ExampleRepo\",\"project\":{\"id\":\"22222222-2222-2222-2222-222222222222\"}}";
        } else if (path.EndsWith("/pullRequests")) {
            body = "{\"value\":[],\"count\":0}";
        } else if (path.EndsWith("/pullRequests/7")) {
            body = "{\"pullRequestId\":7,\"status\":\"active\",\"isDraft\":false,\"sourceRefName\":\"refs/heads/feature\",\"targetRefName\":\"refs/heads/master\",\"repository\":{\"id\":\"11111111-1111-1111-1111-111111111111\",\"project\":{\"id\":\"22222222-2222-2222-2222-222222222222\"}},\"lastMergeSourceCommit\":{\"commitId\":\"" +
                new string('a', 40) + "\"},\"lastMergeTargetCommit\":{\"commitId\":\"" +
                new string('b', 40) + "\"}}";
        } else if (path.EndsWith("/pullRequests/7/iterations")) {
            body = "{\"value\":[{\"id\":1,\"sourceRefCommit\":{\"commitId\":\"" +
                new string('a', 40) + "\"},\"targetRefCommit\":{\"commitId\":\"" +
                new string('b', 40) + "\"},\"commonRefCommit\":{\"commitId\":\"" +
                new string('c', 40) + "\"}}]}";
        } else if (path.EndsWith("/refs")) {
            var feature = request.RequestUri.Query.Contains("feature");
            body = "{\"value\":[{\"name\":\"refs/heads/" +
                (feature ? "feature" : "master") + "\",\"objectId\":\"" +
                new string(DriftRef ? 'f' : (feature ? 'a' : 'b'), 40) + "\"}]}";
        } else if (path.EndsWith("/pullRequests/7/iterations/1/changes")) {
            if (GraphEnabled && !request.RequestUri.Query.Contains("skip=1")) {
                body = "{\"changeEntries\":[{\"changeTrackingId\":1,\"changeType\":\"add\",\"item\":{\"path\":\"/Tests/Example.cs\",\"objectId\":\"" +
                    SourceObjectId + "\"}}],\"count\":1,\"totalCount\":1,\"nextSkip\":" +
                    (IncompleteChanges ? "5" : "1") + "}";
            } else {
                body = "{\"changeEntries\":[],\"count\":0,\"totalCount\":" +
                    (GraphEnabled ? "1" : "0") + ",\"nextSkip\":0}";
            }
        } else if (GraphEnabled && path.EndsWith("/items") &&
                   request.Headers.Accept.ToString() == "application/octet-stream") {
            body = Uri.UnescapeDataString(request.RequestUri.Query).Contains("path=/Tests/Tests.csproj")
                ? ProjectFile : SourceFile;
        } else if (GraphEnabled && path.EndsWith("/commits/" + new string('a', 40))) {
            body = "{\"commitId\":\"" + new string('a', 40) +
                "\",\"treeId\":\"" + RootTreeId + "\"}";
        } else if (GraphEnabled && path.EndsWith("/trees/" + RootTreeId)) {
            body = "{\"objectId\":\"" + RootTreeId +
                "\",\"treeEntries\":[{\"relativePath\":\"Tests\",\"mode\":\"40000\",\"gitObjectType\":\"tree\",\"objectId\":\"" +
                (CorruptTree ? new string('f', 40) : TestsTreeId) + "\"}]}";
        } else if (GraphEnabled && path.EndsWith("/trees/" + TestsTreeId)) {
            body = "{\"objectId\":\"" + TestsTreeId +
                "\",\"treeEntries\":[{\"relativePath\":\"Example.cs\",\"mode\":\"100644\",\"gitObjectType\":\"blob\",\"objectId\":\"" +
                SourceObjectId + "\"}" + (MissingProject ? "" :
                ",{\"relativePath\":\"Tests.csproj\",\"mode\":\"100644\",\"gitObjectType\":\"blob\",\"objectId\":\"" +
                ProjectObjectId + "\"}") + "]}";
        } else if (path.EndsWith("/items") &&
                   request.Headers.Accept.ToString() == "application/octet-stream") {
            body = "synthetic bytes";
        } else if (path.EndsWith("/commits/" + new string('a', 40))) {
            body = "{\"commitId\":\"" + new string('a', 40) + "\"}";
        } else if (path.EndsWith("/trees/" + new string('a', 40))) {
            body = "{\"treeId\":\"" + new string('a', 40) + "\"}";
        } else if (path.EndsWith("/threads")) {
            body = "{\"value\":[],\"count\":0}";
        } else {
            throw new InvalidOperationException("unexpected GET route");
        }
        var response = new HttpResponseMessage(
            (ThrottleInventory && path.EndsWith("/pullRequests")) ||
            (ThrottleTree && path.Contains("/trees/"))
                ? (HttpStatusCode)429 : HttpStatusCode.OK) {
            Content = new ByteArrayContent(TooLarge ? new byte[65537] :
                Encoding.UTF8.GetBytes(body))
        };
        response.Content.Headers.ContentType =
            new System.Net.Http.Headers.MediaTypeHeaderValue(
                path.EndsWith("/items") &&
                    request.Headers.Accept.ToString() == "application/octet-stream"
                    ? "application/octet-stream" : "application/json");
        return Task.FromResult(response);
    }
}
'@
    $module = Get-Module DevPilot.ActivePrCanary
    $script:roots = [Collections.Generic.List[string]]::new()
    $script:old = & $module {
        @{ owner = $script:OwnerHash; named = $script:NamedSectionHash
            namedLength = $script:NamedSectionLength
            coverage = $script:CoverageDocumentHash
            coverageLength = $script:CoverageDocumentLength
            mergedPin = $script:MergedMasterPin }
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
    function Get-BoundGitObjectId([string]$Kind, [byte[]]$Bytes) {
        $header = [Text.Encoding]::ASCII.GetBytes("$Kind $($Bytes.Length)`0")
        [Convert]::ToHexString([Security.Cryptography.SHA1]::HashData(
                [byte[]]($header + $Bytes))).ToLowerInvariant()
    }
    function Get-BoundTreeId([object[]]$Entries) {
        $stream = [IO.MemoryStream]::new()
        try {
            foreach ($entry in $Entries) {
                $prefix = [Text.Encoding]::UTF8.GetBytes(
                    "$($entry.mode) $($entry.name)`0")
                $stream.Write($prefix, 0, $prefix.Length)
                $hash = [Convert]::FromHexString($entry.objectId)
                $stream.Write($hash, 0, $hash.Length)
            }
            Get-BoundGitObjectId 'tree' $stream.ToArray()
        }
        finally { $stream.Dispose() }
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
        $declarations = @(Get-CanaryCoverageDeclarations $CoverageDocument `
                '44444444-4444-4444-4444-444444444444' ('d' * 40))
        $header = [Text.Encoding]::ASCII.GetBytes("blob $($bytes.Length)`0")
        $blobId = [Convert]::ToHexString(
            [Security.Cryptography.SHA1]::HashData(
                [byte[]]($header + $bytes))).ToLowerInvariant()
        $script:MergedMasterPin = @{
            sourceCommit = $script:CoverageCommit
            mergeCommit = 'd' * 40
            documentHash = $script:CoverageDocumentHash
            documentLength = $bytes.Length
            blobId = $blobId
            sectionHash = $declarations[0].sectionHash
            classLineHash = $declarations[0].policyLineHash
            redundantLineHash = $declarations[1].policyLineHash
            classDeclarationDigest = $declarations[0].declarationDigest
            redundantDeclarationDigest = $declarations[1].declarationDigest
        }
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
            master = 'e' * 40
            headChecks = 0
            refChecks = 0
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
            } elseif ($request.commit -ceq $state.head -and
                $state.wrong -eq 'candidate-content') {
                $state.coverage + ' changed on reviewed source'
            } elseif ($request.commit -ceq ('d' * 40) -and
                $state.wrong -eq 'merge-content') {
                $state.coverage + ' changed at merge'
            } elseif ($request.commit -ceq $state.master -and
                $state.wrong -eq 'master-content') {
                $state.coverage + ' changed on master'
            } else { $state.coverage }
            $bytes = [Text.Encoding]::UTF8.GetBytes($text)
            $header = [Text.Encoding]::ASCII.GetBytes("blob $($bytes.Length)`0")
            $oid = [Convert]::ToHexString([Security.Cryptography.SHA1]::HashData(
                    [byte[]]($header + $bytes))).ToLowerInvariant()
            switch -CaseSensitive ($op) {
                IdentityProof {
                    return @{ id = '33333333-3333-3333-3333-333333333333'
                        descriptor = if ($state.wrong -eq 'principal-final' -and
                            $state.reads.Count -gt 10) { 'aad.other' }
                        else { 'aad.synthetic' }
                        uniqueName = if ($state.wrong -eq 'principal') {
                            'other@example.invalid'
                        } elseif ($state.wrong -eq 'missing-unique-name') {
                            $null
                        } else { 'service@example.invalid' } }
                }
                GraphUser {
                    return @{ descriptor = $request.subjectDescriptor
                        subjectKind = 'user'
                        principalName = if ($state.wrong -eq 'graph-upn') {
                            'other@example.invalid'
                        } else { 'service@example.invalid' } }
                }
                GraphStorageKey {
                    return @{ value = if ($state.wrong -eq 'storage-key') {
                            '44444444-4444-4444-4444-444444444444'
                        } else { '33333333-3333-3333-3333-333333333333' } }
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
                    return @{ pullRequestId = 17307009
                        status = if ($state.wrong -eq 'active-pr') {
                            'active'
                        } else { 'completed' }
                        targetRefName = 'refs/heads/master'
                        sourceRefName = 'refs/heads/synthetic-review'
                        repository = @{ id = $engRepoId
                            project = @{ id = $engProjectId; name = 'Engineering' } }
                        lastMergeCommit = @{ commitId = 'd' * 40 }
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
                    $state.refChecks++
                    return @{ value = @(@{ name = 'refs/heads/master'
                                objectId = if ($state.wrong -eq 'master-ref-drift' -and
                                    $state.refChecks -gt 1) {
                                    'f' * 40
                                } else { $state.master } }) }
                }
                Commit {
                    if ($state.wrong -eq 'no-ancestry') {
                        return @{ commitId = $request.commit
                            parents = @('b' * 40) }
                    }
                    return @{ commitId = if ($state.wrong -eq 'commit') {
                            'a' * 40
                        } else { $request.commit }
                        parents = @('d' * 40) }
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
        param([switch]$MissingUniqueName)
        $case = Get-BootstrapCase
        if ($MissingUniqueName) { $case.state.wrong = 'missing-unique-name' }
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
        param([switch]$Code, [switch]$MissingUniqueName)
        $inputCase = Get-RegistryCase -MissingUniqueName:$MissingUniqueName
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
                    if ($state.wrong -eq 'throttle-changes') {
                        throw 'read-throttled'
                    }
                    if ($state.wrong -eq 'provider-drift') {
                        $config.expectedAccount.uniqueName = 'other@example.invalid'
                    }
                    $graph = if ($state.code -and
                        $state.wrong -ne 'unknown-project') {
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
                    } elseif ($state.code -and
                        $state.wrong -eq 'unknown-project') {
                        $receipt = @(@{ pathDigest = $digest
                                objectId = $state.objectId
                                status = 'unknown'; attestationDigest = $null })
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
                            complete = $state.wrong -ne 'unknown-project'
                            files = $receipt
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
            if ($state.wrong -eq 'throttle-final' -and
                $operation -ceq 'GraphStorageKey' -and
                @($state.calls | Where-Object { $_ -ceq 'ListPage' }).Count -gt 0) {
                throw 'read-throttled'
            }
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
                    -RuleSection $ruleId -RuleHash $rule.sourceHash `
                    -RuleLength $source.documentLength `
                    -ConfigId 'private-merged-master-canary-v1' `
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
        $script:MergedMasterPin = $Previous.mergedPin
    } $script:old
    foreach ($root in $script:roots) {
        if (Test-Path -LiteralPath $root) {
            Remove-Item -LiteralPath $root -Recurse -Force
        }
    }
}
Describe 'Read-only private canary input bootstrap' {
    It 'discovers only sanitized unapproved metadata with no pin, state, or writes' {
        $c = Get-BootstrapCase
        $module = Get-Module DevPilot.ActivePrCanary
        $syntheticPin = & $module { $script:MergedMasterPin }
        try {
            & $module { $script:MergedMasterPin = $null }
            $result = Invoke-CanaryMergedMasterDiscovery `
                -Organization 'example-org' `
                -ExpectedAccountUniqueName 'service@example.invalid' `
                -RepositoryRoot $repo -Read $c.provider -Run
            $result.state | Should -Be 'discovered-awaiting-human-source-review'
            $result.candidateBytesMatch | Should -BeTrue
            $result.proposedPin.mergeCommit | Should -Be ('d' * 40)
            $result.proposedPin.sourceCommit |
                Should -Be '7e6620ec40c9bc37c5a5e13d506053b0139c9206'
            $result.observedMasterCommit | Should -Be ('e' * 40)
            $result.proposedPin.documentHash |
                Should -Be $syntheticPin.documentHash
            $result.proposedPin.classDeclarationDigest |
                Should -Not -Be $result.proposedPin.redundantDeclarationDigest
            @($c.state.reads | Where-Object { $_ -eq 'GraphStorageKey' }).Count |
                Should -Be 2
            @($c.state.reads | Where-Object {
                    $_ -eq 'RawItem'
                }).Count | Should -Be 3
            $result.providerWrites | Should -Be 0
            (ConvertTo-Json -InputObject $result -Depth 10) |
                Should -Not -Match 'service@example.invalid|Synthetic convention|/documentation|aad.synthetic|bearer'
            Test-Path -LiteralPath $c.root | Should -BeFalse
        }
        finally {
            & $module { param($Pin) $script:MergedMasterPin = $Pin } $syntheticPin
        }
    }
    It 'refuses discovery for active, changed, unproved, or mismatched identity' {
        foreach ($failure in @('active-pr', 'candidate-content',
                'merge-content', 'master-content', 'no-ancestry',
                'master-ref-drift', 'graph-upn')) {
            $c = Get-BootstrapCase
            $c.state.wrong = $failure
            { Invoke-CanaryMergedMasterDiscovery -Organization 'example-org' `
                    -ExpectedAccountUniqueName 'service@example.invalid' `
                    -RepositoryRoot $repo -Read $c.provider -Run } |
                Should -Throw -Because $failure
            Test-Path -LiteralPath $c.root | Should -BeFalse
            @($c.state.reads | Where-Object {
                    $_ -in @('Write', 'Post', 'ListPage')
                }).Count | Should -Be 0
        }
    }
    It 'rejects even self-consistent newly pinned content before a GET' {
        $c = Get-BootstrapCase
        $module = Get-Module DevPilot.ActivePrCanary
        $originalPin = & $module { @{} + $script:MergedMasterPin }
        try {
            & $module {
                $script:MergedMasterPin.documentHash = 'a' * 64
                $script:MergedMasterPin.documentLength++
                $script:MergedMasterPin.sectionHash = 'v1:sha256:' + 'a' * 64
            }
            { Invoke-BootstrapCase $c } |
                Should -Throw '*merged-master-pin-unavailable*'
            $c.state.reads.Count | Should -Be 0
            Test-Path -LiteralPath $c.root | Should -BeFalse
        }
        finally {
            & $module { param($Pin) $script:MergedMasterPin = $Pin } $originalPin
        }
    }
    It 'has no live source pin and stops the stateless gate before any GET or state' {
        $c = Get-BootstrapCase
        $module = Get-Module DevPilot.ActivePrCanary
        $syntheticPin = & $module { $script:MergedMasterPin }
        try {
            & $module { $script:MergedMasterPin = $null }
            { Invoke-CanaryMergedMasterPreflight -Organization 'example-org' `
                    -ExpectedAccountUniqueName 'service@example.invalid' `
                    -RepositoryRoot $repo -Read $c.provider -Run } |
                Should -Throw '*merged-master-pin-unavailable*'
            { Invoke-BootstrapCase $c } |
                Should -Throw '*merged-master-pin-unavailable*'
            $c.state.reads.Count | Should -Be 0
            Test-Path -LiteralPath $c.root | Should -BeFalse
        }
        finally {
            & $module { param($Pin) $script:MergedMasterPin = $Pin } $syntheticPin
        }
    }
    It 'proves a completed PR and advanced master in memory and rechecks the account' {
        $c = Get-BootstrapCase
        $c.state.master = 'f' * 40
        $proof = Invoke-CanaryMergedMasterPreflight -Organization 'example-org' `
            -ExpectedAccountUniqueName 'service@example.invalid' `
            -RepositoryRoot $repo -Read $c.provider -Run
        $proof.state | Should -Be 'merged-master-proved-read-only'
        $proof.mergeCommit | Should -Be ('d' * 40)
        $proof.masterCommit | Should -Be ('f' * 40)
        $proof.providerWrites | Should -Be 0
        @($c.state.reads | Where-Object { $_ -eq 'GraphStorageKey' }).Count |
            Should -Be 2
        Test-Path -LiteralPath $c.root | Should -BeFalse
    }
    It 'rejects active PR, changed master bytes and unproved history before a root' {
        foreach ($failure in @('active-pr', 'master-content',
                'master-ref-drift', 'no-ancestry')) {
            $c = Get-BootstrapCase
            $c.state.wrong = $failure
            { Invoke-BootstrapCase $c } | Should -Throw -Because $failure
            Test-Path -LiteralPath $c.root | Should -BeFalse
            @($c.state.reads | Where-Object {
                    $_ -in @('Write', 'Post')
                }).Count | Should -Be 0
        }
    }
    It 'rejects changed merged section and either declaration line independently' {
        $module = Get-Module DevPilot.ActivePrCanary
        foreach ($failure in @('section', 'class-line', 'redundant-line')) {
            $c = Get-BootstrapCase
            $originalPin = & $module { @{} + $script:MergedMasterPin }
            try {
                $c.state.coverage = switch ($failure) {
                    section { $c.state.coverage.Replace(
                        '## Synthetic project policy', '## Changed project policy') }
                    'class-line' { $c.state.coverage.Replace(
                        'Every class uses an exclusion.', 'Class excludes coverage.') }
                    'redundant-line' { $c.state.coverage.Replace(
                        'Method exclusion is redundant.', 'Redundant method changed.') }
                }
                & $module {
                    param($Document, $RebindSection)
                    $bytes = [Text.Encoding]::UTF8.GetBytes($Document)
                    $header = [Text.Encoding]::ASCII.GetBytes(
                        "blob $($bytes.Length)`0")
                    $script:MergedMasterPin.documentHash = Get-CanaryHash $bytes
                    $script:MergedMasterPin.documentLength = $bytes.Length
                    $script:MergedMasterPin.blobId = [Convert]::ToHexString(
                        [Security.Cryptography.SHA1]::HashData(
                            [byte[]]($header + $bytes))).ToLowerInvariant()
                    if ($RebindSection) {
                        $declarations = @(Get-CanaryCoverageDeclarations $Document `
                            '44444444-4444-4444-4444-444444444444' ('d' * 40))
                        $script:MergedMasterPin.sectionHash =
                            $declarations[0].sectionHash
                    }
                } $c.state.coverage ($failure -ne 'section')
                { Invoke-BootstrapCase $c } |
                    Should -Throw '*merged-master-pin-unavailable*'
                Test-Path -LiteralPath $c.root | Should -BeFalse
            }
            finally {
                & $module { param($Pin) $script:MergedMasterPin = $Pin } $originalPin
            }
        }
    }
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
            $result.state | Should -Be 'merged-master-read-only'
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
                    'config', 'schema-downgrade', 'head', 'commit',
                    'graph', 'principal')) {
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
                    'schema-downgrade' {
                        Sign-RunnerConfig $c {
                            param($value)
                            $value.schemaVersion = 2
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
        It 'rejects a correctly re-signed previous-version dispatcher' {
            $c = Get-SignedIntakeCase
            [void](Invoke-SignedIntakeCase $c)
            $c.state.calls.Clear()
            Sign-RunnerConfig $c {
                param($value)
                $value.schemaVersion = 2
            }
            { Invoke-RunnerCase $c } | Should -Throw '*canary-config-invalid*'
            $c.state.calls.Count | Should -Be 0
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
            $body | Should -Match 'merged-master read-only convention'
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
    It 'carries absent ADO uniqueName as absent through receipts and signed evaluation' {
        $c = Get-SignedIntakeCase -Code -MissingUniqueName
        $c.input.config.expectedAccount.Contains('uniqueName') | Should -BeFalse
        $c.input.sources.accountProofDigest | Should -Match '^v1:sha256:[a-f0-9]{64}$'
        $signed = Invoke-SignedIntakeCase $c
        $signed.state | Should -Be 'signed-intake-not-evaluated'
        $dispatcher = Get-Content (Join-Path $c.root 'canary-dispatcher.json') `
            -Raw | ConvertFrom-Json -AsHashtable
        $dispatcher.schemaVersion | Should -Be 3
        $dispatcher.expectedAccount.Contains('uniqueName') | Should -BeFalse
        $result = Invoke-RunnerCase $c
        $result.schemaVersion | Should -Be 3
        $result.providerWrites | Should -Be 0
        $result.modelToolInvocations | Should -Be 0
        $c.state.threads = @(New-RunnerThread $c 1 'Exclude from code coverage.')
        $human = Invoke-RunnerCase $c
        $human.rules[1].humanCovered | Should -Be 2
        $human.rules[1].wouldCreate | Should -Be 0
        $marker = New-RunnerThread $c 1 (Get-RunnerClassMarkerBody $c)
        $marker.comments[0].author = [ordered]@{} + $c.input.config.expectedAccount
        $marker.comments[0].author.descriptor = 'aad.other'
        $c.state.threads = @($marker)
        $ambiguous = Invoke-RunnerCase $c
        $ambiguous.rules[1].unknown | Should -Be 2
        $ambiguous.rules[1].wouldCreate | Should -Be 0
    }
    It 'refuses a half-injected credential path without creating state' {
        $c = Get-SignedIntakeCase
        { Invoke-PrivateCanarySignedIntake -ProviderConfig $c.input.config `
                -ApprovedSources $c.input.sources -StateRoot $c.root `
                -RepositoryRoot $repo -CanaryPullRequestIds @(17007699) `
                -Read $c.read -Run } | Should -Throw '*bound-transport-invalid*'
        Test-Path $c.root | Should -BeFalse
        $c.state.calls.Count | Should -Be 0
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
                        'provider-drift', 'throttle-final')) {
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
                    Test-Path $c.root | Should -BeFalse
                    Test-Path (Join-Path $c.root 'signature.key') | Should -BeFalse
                    @($c.state.calls | Where-Object {
                            $_ -notin @('Identity', 'ListPage', 'Head', 'Changes',
                                'Discussions')
                        }).Count | Should -Be 0
                }
            }
            It 'keeps the private root absent through complete and failed signed-intake proofs' {
                foreach ($mode in @('complete', 'split-page',
                        'unknown-project', 'stale-head', 'throttle-changes',
                        'throttle-final')) {
                    $c = Get-SignedIntakeCase -Code
                    if ($mode -ne 'complete') { $c.state.wrong = $mode }
                    $root = $c.root
                    $originalRead = $c.read
                    $originalProvider = $c.provider
                    $observed = @{ source = 0; intake = 0 }
                    $c.read = {
                        param($operation, $request)
                        if (Test-Path -LiteralPath $root) {
                            throw 'state-created-before-source-proof'
                        }
                        $observed.source++
                        & $originalRead $operation $request
                    }.GetNewClosure()
                    $c.provider = {
                        param($operation, $request)
                        if (Test-Path -LiteralPath $root) {
                            throw 'state-created-before-intake-proof'
                        }
                        $observed.intake++
                        & $originalProvider $operation $request
                    }.GetNewClosure()
                    if ($mode -eq 'complete') {
                        (Invoke-SignedIntakeCase $c).state |
                            Should -Be 'signed-intake-not-evaluated'
                        (Test-Path -LiteralPath (
                                Join-Path $root 'signature.key')) |
                            Should -BeTrue
                    } else {
                        $message = try {
                            [void](Invoke-SignedIntakeCase $c)
                            ''
                        } catch { $_.Exception.Message }
                        $message | Should -Not -BeNullOrEmpty
                        $message | Should -Not -Match 'state-created-before-'
                        Test-Path -LiteralPath $root | Should -BeFalse
                    }
                    $observed.source | Should -BeGreaterThan 0
                    $observed.intake | Should -BeGreaterThan 0
                    if ($mode -eq 'throttle-changes') {
                        @($c.state.calls | Where-Object { $_ -eq 'Head' }).Count |
                            Should -Be 1
                        @($c.state.calls | Where-Object {
                                $_ -eq 'Discussions'
                            }).Count | Should -Be 0
                    }
                    @($c.state.calls | Where-Object {
                            $_ -notin @('Identity', 'ListPage', 'Head',
                                'Changes', 'Discussions')
                        }).Count | Should -Be 0
                }
            }
            It 'removes only its canonical root after an aliased post-proof file failure' {
                $c = Get-SignedIntakeCase -Code
                $canonical = [IO.Path]::GetFullPath($c.root)
                $sibling = "$canonical-neighbor"
                $script:roots.Add($sibling)
                [void](New-Item -ItemType Directory -Path $sibling)
                [IO.File]::WriteAllText((Join-Path $sibling 'keep.txt'), 'keep')
                $c.root = Join-Path (Split-Path $canonical -Parent) (
                    '.\' + (Split-Path $canonical -Leaf))
                Mock Write-CanaryPrivateFile -ModuleName DevPilot.ActivePrCanary {
                    throw 'signed-file-failed'
                } -ParameterFilter { $Path -like '*canary-dispatcher.json' }
                { Invoke-SignedIntakeCase $c } |
                    Should -Throw '*signed-file-failed*'
                Test-Path -LiteralPath $canonical | Should -BeFalse
                [IO.File]::ReadAllText((Join-Path $sibling 'keep.txt')) |
                    Should -Be 'keep'
                @($c.state.calls | Where-Object {
                        $_ -in @('Write', 'Post')
                    }).Count | Should -Be 0
            }
            It 'removes only a root attributed to itself after partial ACL creation' {
                $c = Get-SignedIntakeCase -Code
                $canonical = [IO.Path]::GetFullPath($c.root)
                $sibling = "$canonical-neighbor"
                $script:roots.Add($sibling)
                [void](New-Item -ItemType Directory -Path $sibling)
                [IO.File]::WriteAllText((Join-Path $sibling 'keep.txt'), 'keep')
                $c.root = Join-Path (Split-Path $canonical -Parent) (
                    '.\' + (Split-Path $canonical -Leaf))
                Mock Resolve-AgentTrustedRoot -ModuleName DevPilot.ActivePrIntake {
                    [void](New-Item -ItemType Directory -Path $Path)
                    $CreatedByCaller.Value = $true
                    throw 'synthetic-acl-failed'
                } -ParameterFilter { $Create -and $Path -ceq $canonical }
                { Invoke-SignedIntakeCase $c } |
                    Should -Throw '*synthetic-acl-failed*'
                Test-Path -LiteralPath $canonical | Should -BeFalse
                [IO.File]::ReadAllText((Join-Path $sibling 'keep.txt')) |
                    Should -Be 'keep'
            }
            It 'removes its new root when opening the post-proof lock fails' {
                $c = Get-SignedIntakeCase -Code
                $canonical = [IO.Path]::GetFullPath($c.root)
                $sibling = "$canonical-neighbor"
                $script:roots.Add($sibling)
                [void](New-Item -ItemType Directory -Path $sibling)
                [IO.File]::WriteAllText((Join-Path $sibling 'keep.txt'), 'keep')
                Mock Resolve-AgentTrustedRoot -ModuleName DevPilot.ActivePrIntake {
                    [void](New-Item -ItemType Directory -Path $Path)
                    [void](New-Item -ItemType Directory -Path (
                            Join-Path (Split-Path $Path -Parent) 'cohort.lock'))
                    return $Path
                } -ParameterFilter {
                    $Create -and $Path -ceq (
                        Join-Path $canonical 'active-pr-intake-v1\generations')
                }
                { Invoke-SignedIntakeCase $c } | Should -Throw
                Test-Path -LiteralPath $canonical | Should -BeFalse
                [IO.File]::ReadAllText((Join-Path $sibling 'keep.txt')) |
                    Should -Be 'keep'
            }
            It 'never deletes an existing signed root presented through a path alias' {
                $c = Get-SignedIntakeCase
                $canonical = [IO.Path]::GetFullPath($c.root)
                [void](New-Item -ItemType Directory -Path $canonical)
                [IO.File]::WriteAllText((Join-Path $canonical 'keep.txt'), 'keep')
                $c.root = Join-Path (Split-Path $canonical -Parent) (
                    '.\' + (Split-Path $canonical -Leaf))
                { Invoke-SignedIntakeCase $c } |
                    Should -Throw '*canary-state-root-must-be-new*'
                [IO.File]::ReadAllText((Join-Path $canonical 'keep.txt')) |
                    Should -Be 'keep'
                $c.state.calls.Count | Should -Be 0
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
            $result.providerReads | Should -Be 24
            $result.rules.Count | Should -Be 4
            $result.rules['bpm-test-ownership@1'].sourceAuthority |
                Should -Be 'pinned-owner-section'
            $result.rules['bpm-test-class-coverage@2'].sourceAuthority |
                Should -Be 'verified-merged-master-read-only'
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
            foreach ($failure in @('schema', 'previous-v3', 'identity-digest', 'missing',
                    'owner', 'owner-length',
                    'named-section', 'named-blob', 'class', 'redundant',
                    'class-master', 'named-policy', 'named-digest', 'repository',
                    'project')) {
                $inputCase = Get-RegistryCase
                switch ($failure) {
                    schema { $inputCase.sources.schemaVersion = 2 }
                    'previous-v3' {
                        $inputCase.sources.schemaVersion = 3
                        $inputCase.sources.kind = 'private-read-only-canary-sources'
                        $inputCase.sources.sourceAuthority =
                            'unmerged-reviewed-pr-is-candidate-only'
                    }
                    'identity-digest' {
                        $inputCase.sources.accountProofDigest = 'v1:sha256:' + 'a' * 64
                    }
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
                    'class-master' {
                        $inputCase.sources.rules['bpm-test-class-coverage@2'].masterCommit =
                            'f' * 40
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
        $c.state.reads.Count | Should -BeLessOrEqual 120
        $c.state.reads[-1] | Should -Be 'GraphStorageKey'
        @($c.state.reads | Where-Object { $_ -in @('ListPage', 'Head', 'Changes',
                    'Discussions', 'Write', 'Post') }).Count | Should -Be 0
        $config = Get-Content (Join-Path $c.root 'provider-config.json') -Raw |
            ConvertFrom-Json -AsHashtable
        $manifest = Get-Content (Join-Path $c.root 'approved-sources.json') -Raw |
            ConvertFrom-Json -AsHashtable
        $config.projectId | Should -Be '22222222-2222-2222-2222-222222222222'
        $config.repository.id | Should -Be '11111111-1111-1111-1111-111111111111'
        $config.expectedAccount.descriptor | Should -Be 'aad.synthetic'
        $config.expectedAccount.principalName | Should -Be 'service@example.invalid'
        $manifest.schemaVersion | Should -Be 4
        $manifest.rules.Count | Should -Be 4
        $manifest.namedSection.commit | Should -Be $manifest.rules['bpm-test-ownership@1'].commit
        $manifest.rules['bpm-test-class-coverage@2'].masterCommit |
            Should -Be ('e' * 40)
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
                'principal', 'graph-upn', 'storage-key', 'commit', 'blob', 'source-path',
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
    It 'removes a newly created bootstrap root if private receipt writing fails' {
        $c = Get-BootstrapCase
        Mock Write-CanaryPrivateFile -ModuleName DevPilot.ActivePrCanary {
            throw 'receipt-write-failed'
        } -ParameterFilter { $Path -like '*approved-sources.json' }
        { Invoke-BootstrapCase $c } | Should -Throw '*receipt-write-failed*'
        Test-Path $c.root | Should -BeFalse
        @($c.state.reads | Where-Object { $_ -in @('Write', 'Post') }).Count |
            Should -Be 0
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
            $message | Should -Be 'bootstrap-read-inaccessible:IdentityProof:http-302'
            Test-Path $c.root | Should -BeFalse
            $state.reads.Count | Should -Be 1
            $state.reads[0] | Should -Be 'IdentityProof'
            $handler.Paths.Count | Should -Be 1
        }
        finally { $client.Dispose() }
    }
    It 'accepts ordinary remaining-budget telemetry and stops on real throttle' {
        foreach ($mode in @('budget', '429', '503', 'retry-after', 'exhausted')) {
            $handler = [CanarySyntheticHandler]::new()
            if ($mode -in @('429', '503')) {
                $handler.Status = [Net.HttpStatusCode][int]$mode
            }
            if ($mode -eq 'retry-after') { $handler.ThrottleHint = $true }
            if ($mode -eq 'budget') { $handler.BudgetRemaining = '8' }
            if ($mode -eq 'exhausted') { $handler.BudgetRemaining = '0' }
            $client = [Net.Http.HttpClient]::new($handler)
            $module = Get-Module DevPilot.ActivePrCanary
            try {
                $read = {
                    & $module {
                        param($Client)
                        Invoke-CanaryAadGet $Client 'synthetic-bearer' `
                            'example-org' 'Project' @{ projectName = 'Engineering' } `
                            ([DateTime]::UtcNow.AddSeconds(5))
                    } $client
                }
                if ($mode -eq 'budget') {
                    (& $read).id | Should -Be 'synthetic'
                } else {
                    { & $read } | Should -Throw '*bootstrap-read-throttled:Project*'
                }
                $handler.Paths.Count | Should -Be 1
            }
            finally { $client.Dispose() }
        }
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
            $message | Should -Be 'bootstrap-read-inaccessible:IdentityProof:send'
            Test-Path $c.root | Should -BeFalse
            $state.reads.Count | Should -Be 1
            $state.reads[0] | Should -Be 'IdentityProof'
            $handler.Paths.Count | Should -Be 1
        }
        finally { $client.Dispose() }
    }
    It 'redacts bounded response read and decode failures without private state' {
        foreach ($case in @(
                @{ phase = 'read'; oversize = $true; invalidJson = $false },
                @{ phase = 'invalid-json'; oversize = $false; invalidJson = $true })) {
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
                $message | Should -Be "bootstrap-read-inaccessible:IdentityProof:$($case.phase)"
                Test-Path $c.root | Should -BeFalse
                $state.reads.Count | Should -Be 1
                $state.reads[0] | Should -Be 'IdentityProof'
                $handler.Paths.Count | Should -Be 1
            }
            finally { $client.Dispose() }
        }
    }
    It 'classifies only fixed reasons from one bounded GET without creating state' {
        $utf8 = [Text.Encoding]::UTF8
        $nested = '{"authenticatedUser":{"id":"synthetic","subjectDescriptor":"aad.synthetic","uniqueName":"service@example.invalid"},"locationServiceData":' +
            ('{"child":' * 14) + '{}' + ('}' * 14) + '}'
        foreach ($case in @(
                @{ reason = 'non-json-media'; bytes = $utf8.GetBytes('<html>Sign in</html>'); media = 'text/html'; encoding = $null },
                @{ reason = 'encoded-response'; bytes = $utf8.GetBytes('{}'); media = 'application/json'; encoding = 'gzip' },
                @{ reason = 'invalid-utf8'; bytes = [byte[]]@(0xff, 0xfe); media = 'application/json'; encoding = $null },
                @{ reason = 'invalid-json'; bytes = $utf8.GetBytes('{"authenticatedUser":'); media = 'application/json'; encoding = $null },
                @{ reason = 'utf8-bom'; bytes = [byte[]]@(0xef, 0xbb, 0xbf) + $utf8.GetBytes('{}'); media = 'application/json'; encoding = $null },
                @{ reason = 'json-depth-over-12'; bytes = $utf8.GetBytes($nested); media = 'application/json'; encoding = $null },
                @{ reason = 'identity-fields-missing'; bytes = $utf8.GetBytes('{"authenticatedUser":{"id":"synthetic"}}'); media = 'application/json'; encoding = $null },
                @{ reason = 'identity-fields-missing'; bytes = $utf8.GetBytes('{}'); media = 'application/json'; encoding = $null })) {
            $handler = [CanarySyntheticHandler]::new()
            $handler.Body = $case.bytes
            if ($case.media) { $handler.MediaType = $case.media }
            if ($case.encoding) { $handler.ContentEncoding = $case.encoding }
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
                $handler.Paths.Count | Should -Be 1
                $message | Should -Be "bootstrap-read-inaccessible:IdentityProof:$($case.reason)"
                Test-Path $c.root | Should -BeFalse
                $state.reads.Count | Should -Be 1
                $state.reads[0] | Should -Be 'IdentityProof'
            }
            finally { $client.Dispose() }
        }
    }
    It 'leaves an unexplained parser failure unclassified rather than claiming a cause' {
        Mock ConvertFrom-Json -ModuleName DevPilot.ActivePrCanary {
            throw 'synthetic parser detail'
        } -ParameterFilter { $Depth -eq 12 }
        $module = Get-Module DevPilot.ActivePrCanary
        $reason = & $module {
            Get-CanaryIdentityPayload `
                -Bytes ([Text.Encoding]::UTF8.GetBytes(
                    '{"authenticatedUser":{"id":"synthetic"}}')) `
                -MediaType 'application/json' -Encoded $false
        }
        $reason.reason | Should -Be 'unclassified'
    }
    It 'keeps the one-GET diagnostic disabled and rejects bad selectors without a read' {
        $state = @{ reads = 0 }
        $read = {
            param($operation, $request)
            $state.reads++
            throw 'unexpected diagnostic request'
        }.GetNewClosure()
        $diagnosticArgs = @{
            Organization = 'example-org'
            ExpectedAccountUniqueName = 'service@example.invalid'
            RepositoryRoot = $repo
            Read = $read
        }
        $result = Invoke-PrivateCanaryIdentityDiagnostic @diagnosticArgs
        $result.state | Should -Be 'disabled'
        $result.getAttempts | Should -Be 0
        $invalidArgs = $diagnosticArgs.Clone()
        $invalidArgs.Organization = 'example-org/other'
        { Invoke-PrivateCanaryIdentityDiagnostic @invalidArgs -Run } |
            Should -Throw
        $state.reads | Should -Be 0
    }
    It 'keeps the public diagnostic script default-off without a credential or ADO GET' {
        $json = & (Join-Path $repo 'tools\Invoke-PrivateCanaryIdentityDiagnostic.ps1') `
            -Organization 'example-org' `
            -ExpectedAccountUniqueName 'service@example.invalid'
        $result = $json | ConvertFrom-Json -AsHashtable
        $result.state | Should -Be 'disabled'
        $result.getAttempts | Should -Be 0
        $result.providerWrites | Should -Be 0
    }
    It 'retains sanitized Int64 GET counts after a JSON round trip without another read' {
        foreach ($case in @(
                @{ state = 'unknown'; reason = 'identity-fields-missing'; gets = 1 },
                @{ state = 'unknown'; reason = 'graph-user-mismatch'; gets = 2 },
                @{ state = 'verified'; reason = 'valid'; gets = 3 })) {
            $json = [ordered]@{
                state = $case.state; reason = $case.reason
                getAttempts = $case.gets
                providerWrites = 0; modelToolInvocations = 0
            } | ConvertTo-Json -Compress
            $parsed = $json | ConvertFrom-Json -AsHashtable
            $parsed.getAttempts | Should -BeOfType [long]
            $output = ConvertTo-PrivateCanaryIdentityOutput -Json $json `
                -Run $true -VerifyGraph $true
            $result = $output | ConvertFrom-Json -AsHashtable
            $result.getAttempts | Should -Be $case.gets
            $result.state | Should -Be $case.state
            $result.reason | Should -Be $case.reason
            $result.providerWrites | Should -Be 0
            $result.modelToolInvocations | Should -Be 0
            $output | Should -Not -Match 'example\.invalid|private-sentinel'
        }
        foreach ($json in @(
                '{"state":"verified","reason":"valid","getAttempts":4,"providerWrites":0,"modelToolInvocations":0}',
                '{"state":"verified","reason":"valid","getAttempts":2,"providerWrites":0,"modelToolInvocations":0}',
                '{"state":"unknown","reason":"private-sentinel","getAttempts":1,"providerWrites":0,"modelToolInvocations":0}',
                '{"state":"unknown","reason":"unclassified","getAttempts":1,"providerWrites":0,"modelToolInvocations":0,"identity":"private-sentinel"}',
                '{"state":"unknown","reason":"unclassified","getAttempts":1,"providerWrites":1,"modelToolInvocations":0}',
                '{"state":"unknown","reason":"unclassified","getAttempts":1,"providerWrites":"0","modelToolInvocations":0}',
                '{"state":"unknown","reason":"unclassified","getAttempts":1.5,"providerWrites":0,"modelToolInvocations":0}')) {
            { ConvertTo-PrivateCanaryIdentityOutput -Json $json `
                    -Run $true -VerifyGraph $true } |
                Should -Throw 'identity-diagnostic-result-invalid'
        }
    }
    It 'uses exactly one bounded Identity GET on success and failure without state or private output' {
        foreach ($case in @(
                @{ reason = 'valid'; state = 'verified'; body = $null; media = $null; status = 200; failTransport = $false; expected = 'service@example.invalid' },
                @{ reason = 'principal-mismatch'; state = 'unknown'; body = $null; media = $null; status = 200; failTransport = $false; expected = 'other@example.invalid' },
                @{ reason = 'non-json-media'; state = 'unknown'; body = [Text.Encoding]::UTF8.GetBytes('<html>private-sentinel</html>'); media = 'text/html'; status = 200; failTransport = $false; expected = 'service@example.invalid' },
                @{ reason = 'http-failure'; state = 'unknown'; body = $null; media = $null; status = 302; failTransport = $false; expected = 'service@example.invalid' },
                @{ reason = 'send-failure'; state = 'unknown'; body = $null; media = $null; status = 200; failTransport = $true; expected = 'service@example.invalid' })) {
            $handler = [CanarySyntheticHandler]::new()
            if ($case.body) { $handler.Body = $case.body }
            if ($case.media) { $handler.MediaType = $case.media }
            $handler.Status = [Net.HttpStatusCode]$case.status
            $handler.FailTransport = $case.failTransport
            $client = [Net.Http.HttpClient]::new($handler)
            $module = Get-Module DevPilot.ActivePrCanary
            $c = Get-BootstrapCase
            $state = @{ reads = [Collections.Generic.List[string]]::new() }
            $read = {
                param($operation, $request)
                $state.reads.Add($operation) | Out-Null
                & $module {
                    param($Client, $Operation, $Request)
                    Invoke-CanaryAadGet $Client 'synthetic-bearer' 'example-org' `
                        $Operation $Request ([DateTime]::UtcNow.AddSeconds(5))
                } $client $operation $request
            }.GetNewClosure()
            try {
                $result = Invoke-PrivateCanaryIdentityDiagnostic `
                    -Organization 'example-org' `
                    -ExpectedAccountUniqueName $case.expected `
                    -RepositoryRoot $repo -Read $read -Run
                $result.state | Should -Be $case.state
                $result.reason | Should -Be $case.reason
                $result.getAttempts | Should -Be 1
                $result.providerWrites | Should -Be 0
                $result.modelToolInvocations | Should -Be 0
                $state.reads.Count | Should -Be 1
                $state.reads[0] | Should -Be 'Identity'
                $handler.Paths.Count | Should -Be 1
                Test-Path -LiteralPath $c.root | Should -BeFalse
                $json = ConvertTo-Json -InputObject $result -Compress
                $json | Should -Not -Match 'private-sentinel|example\.invalid|synthetic|http-302'
            }
            finally { $client.Dispose() }
        }
    }
    It 'does not leak unexpected provider errors or make another GET' {
        $state = @{ reads = 0 }
        $read = {
            param($operation, $request)
            $state.reads++
            throw 'private-sentinel'
        }.GetNewClosure()
        $result = Invoke-PrivateCanaryIdentityDiagnostic `
            -Organization 'example-org' `
            -ExpectedAccountUniqueName 'service@example.invalid' `
            -RepositoryRoot $repo -Read $read -Run
        $result.reason | Should -Be 'unclassified'
        $result.getAttempts | Should -Be 1
        $state.reads | Should -Be 1
        (ConvertTo-Json -InputObject $result) | Should -Not -Match 'private-sentinel'
    }
    It 'binds a token identity to the same Graph user and storage key in at most three GETs' {
        $utf8 = [Text.Encoding]::UTF8
        $id = '33333333-3333-3333-3333-333333333333'
        $fullIdentity = '{"authenticatedUser":{"id":"' + $id +
            '","subjectDescriptor":"aad.synthetic","uniqueName":"service@example.invalid"}}'
        $noUniqueName = '{"authenticatedUser":{"id":"' + $id +
            '","subjectDescriptor":"aad.synthetic"}}'
        $missingId = '{"authenticatedUser":{"subjectDescriptor":"aad.synthetic"}}'
        $missingDescriptor = '{"authenticatedUser":{"id":"' + $id + '"}}'
        foreach ($case in @(
                @{ reason = 'valid'; gets = 3; identity = $noUniqueName; user = $null; storage = $null; userStatus = 200 },
                @{ reason = 'valid'; gets = 3; identity = $fullIdentity; user = $null; storage = $null; userStatus = 200 },
                @{ reason = 'identity-fields-missing'; gets = 1; identity = $missingId; user = $null; storage = $null; userStatus = 200 },
                @{ reason = 'identity-fields-missing'; gets = 1; identity = $missingDescriptor; user = $null; storage = $null; userStatus = 200 },
                @{ reason = 'optional-name-mismatch'; gets = 1; identity = $fullIdentity.Replace('service@example.invalid', 'other@example.invalid'); user = $null; storage = $null; userStatus = 200 },
                @{ reason = 'graph-user-mismatch'; gets = 2; identity = $noUniqueName; user = '{"descriptor":"aad.different","subjectKind":"user","principalName":"service@example.invalid"}'; storage = $null; userStatus = 200 },
                @{ reason = 'graph-user-mismatch'; gets = 2; identity = $noUniqueName; user = '{"descriptor":"aad.synthetic","subjectKind":"user","principalName":"other@example.invalid"}'; storage = $null; userStatus = 200 },
                @{ reason = 'graph-user-mismatch'; gets = 2; identity = $noUniqueName; user = '{"descriptor":"aad.synthetic","subjectKind":"group","principalName":"service@example.invalid"}'; storage = $null; userStatus = 200 },
                @{ reason = 'http-failure'; gets = 2; identity = $noUniqueName; user = $null; storage = $null; userStatus = 403 },
                @{ reason = 'http-failure'; gets = 2; identity = $noUniqueName; user = $null; storage = $null; userStatus = 302 },
                @{ reason = 'storage-key-mismatch'; gets = 3; identity = $noUniqueName; user = $null; storage = '{"value":"44444444-4444-4444-4444-444444444444"}'; userStatus = 200 })) {
            $handler = [CanarySyntheticHandler]::new()
            $handler.Body = $utf8.GetBytes($case.identity)
            if ($case.user) { $handler.GraphUserBody = $utf8.GetBytes($case.user) }
            if ($case.storage) { $handler.StorageKeyBody = $utf8.GetBytes($case.storage) }
            $handler.GraphUserStatus = [Net.HttpStatusCode]$case.userStatus
            $client = [Net.Http.HttpClient]::new($handler)
            $module = Get-Module DevPilot.ActivePrCanary
            $c = Get-BootstrapCase
            $state = @{ operations = [Collections.Generic.List[string]]::new() }
            $read = {
                param($operation, $request)
                $state.operations.Add($operation) | Out-Null
                & $module {
                    param($Client, $Operation, $Request)
                    Invoke-CanaryAadGet $Client 'synthetic-bearer' 'example-org' `
                        $Operation $Request ([DateTime]::UtcNow.AddSeconds(5))
                } $client $operation $request
            }.GetNewClosure()
            try {
                $result = Invoke-PrivateCanaryIdentityDiagnostic `
                    -Organization 'example-org' `
                    -ExpectedAccountUniqueName 'service@example.invalid' `
                    -RepositoryRoot $repo -Read $read -VerifyGraph -Run
                $result.reason | Should -Be $case.reason
                $result.state | Should -Be $(if ($case.reason -eq 'valid') {
                        'verified'
                    } else { 'unknown' })
                $result.getAttempts | Should -Be $case.gets
                $result.providerWrites | Should -Be 0
                $result.modelToolInvocations | Should -Be 0
                $state.operations.Count | Should -Be $case.gets
                $handler.Paths.Count | Should -Be $case.gets
                $state.operations[0] | Should -Be 'IdentityProof'
                $handler.Paths[0] | Should -Match '^https://dev\.azure\.com/example-org/_apis/connectionData\?api-version=7\.1-preview\.1$'
                if ($case.gets -gt 1) {
                    $state.operations[1] | Should -Be 'GraphUser'
                    $handler.Paths[1] | Should -Match '^https://vssps\.dev\.azure\.com/example-org/_apis/graph/users/aad\.synthetic\?api-version=7\.1-preview\.1$'
                }
                if ($case.gets -gt 2) {
                    $state.operations[2] | Should -Be 'GraphStorageKey'
                    $handler.Paths[2] | Should -Match '^https://vssps\.dev\.azure\.com/example-org/_apis/graph/storagekeys/aad\.synthetic\?api-version=7\.1$'
                }
                Test-Path -LiteralPath $c.root | Should -BeFalse
                (ConvertTo-Json -InputObject $result -Compress) |
                    Should -Not -Match 'aad\.synthetic|example\.invalid|33333333|private-sentinel'
            }
            finally { $client.Dispose() }
        }
    }
    It 'keeps Graph verification disabled and redacts injected read errors' {
        $state = @{ operations = [Collections.Generic.List[string]]::new() }
        $read = {
            param($operation, $request)
            $state.operations.Add($operation) | Out-Null
            throw 'private-sentinel'
        }.GetNewClosure()
        $args = @{
            Organization = 'example-org'
            ExpectedAccountUniqueName = 'service@example.invalid'
            RepositoryRoot = $repo
            Read = $read
            VerifyGraph = $true
        }
        (Invoke-PrivateCanaryIdentityDiagnostic @args).getAttempts | Should -Be 0
        $state.operations.Count | Should -Be 0
        $result = Invoke-PrivateCanaryIdentityDiagnostic @args -Run
        $result.reason | Should -Be 'unclassified'
        $result.getAttempts | Should -Be 1
        $state.operations.Count | Should -Be 1
        $state.operations[0] | Should -Be 'IdentityProof'
        (ConvertTo-Json -InputObject $result) | Should -Not -Match 'private-sentinel'
    }
    It 'stops after the third attempted GET on an unavailable Graph storage key' {
        $state = @{ operations = [Collections.Generic.List[string]]::new() }
        $read = {
            param($operation, $request)
            $state.operations.Add($operation) | Out-Null
            switch ($operation) {
                IdentityProof {
                    return @{ id = '33333333-3333-3333-3333-333333333333'
                        descriptor = 'aad.synthetic'; uniqueName = $null }
                }
                GraphUser {
                    return @{ descriptor = 'aad.synthetic'; subjectKind = 'user'
                        principalName = 'service@example.invalid' }
                }
                GraphStorageKey { throw 'private-sentinel' }
                default { throw 'unexpected operation' }
            }
        }.GetNewClosure()
        $c = Get-BootstrapCase
        $result = Invoke-PrivateCanaryIdentityDiagnostic `
            -Organization 'example-org' `
            -ExpectedAccountUniqueName 'service@example.invalid' `
            -RepositoryRoot $repo -Read $read -VerifyGraph -Run
        $result.state | Should -Be 'unknown'
        $result.reason | Should -Be 'unclassified'
        $result.getAttempts | Should -Be 3
        $state.operations.ToArray() -join ',' |
            Should -Be 'IdentityProof,GraphUser,GraphStorageKey'
        Test-Path -LiteralPath $c.root | Should -BeFalse
        (ConvertTo-Json -InputObject $result) | Should -Not -Match 'private-sentinel'
    }
    It 'uses one attested bearer on identity, Graph, inventory and discussions' {
        $config = Get-Content (Join-Path $repo 'samples\active-pr-intake.config.json') `
            -Raw | ConvertFrom-Json -AsHashtable
        $config.schemaVersion = 2
        $config.principalProof = 'aad-graph-storage-key-v1'
        $config.expectedAccount.descriptor = 'aad.synthetic'
        $config.expectedAccount.principalName = 'service@example.invalid'
        $config.enabled = $true
        $handler = [CanaryBoundGetHandler]::new()
        $client = [Net.Http.HttpClient]::new($handler)
        try {
            $token = 'b' * 100
            $provider = New-ActivePrAzureDevOpsProvider -Config $config `
                -BearerToken $token -BoundClient $client -VerifyReadPrincipal
            $identity = & $provider Identity @{ timeoutMilliseconds = 5000 }
            $identity.readCount | Should -Be 2
            $identity.principalName | Should -Be 'service@example.invalid'
            $metadata = & $provider Metadata @{
                repositoryName = 'ExampleRepo'; timeoutMilliseconds = 5000 }
            $metadata.repositoryId | Should -Be $config.repositoryId
            $page = & $provider ListPage @{ skip = 0; top = 50
                timeoutMilliseconds = 5000 }
            $page.count | Should -Be 0
            $threads = & $provider Discussions @{
                pullRequestId = 7; timeoutMilliseconds = 5000 }
            $threads.count | Should -Be 0
            $head = & $provider Head @{ pullRequestId = 7
                remainingReads = 10; timeoutMilliseconds = 5000 }
            $head.sourceCommit | Should -Be ('a' * 40)
            $head.readCount | Should -Be 4
            $changes = & $provider Changes @{ pullRequestId = 7
                iterationId = 1; remainingReads = 10
                timeoutMilliseconds = 5000 }
            $changes.changedFiles | Should -Be 0
            $finalHead = & $provider Head @{ pullRequestId = 7
                remainingReads = 10; timeoutMilliseconds = 5000 }
            $finalHead.sourceCommit | Should -Be $head.sourceCommit
            $intakeModule = Get-Module DevPilot.ActivePrIntake
            foreach ($route in @(
                    @{ resource = 'items'; suffix = '/items?'
                        query = @('path=/Tests/Example.cs',
                            "versionDescriptor.version=$('a' * 40)",
                            'versionDescriptor.versionType=commit'); raw = $true },
                    @{ resource = 'commits'; suffix = "/commits/$('a' * 40)?"
                        pathId = 'commitId'; raw = $false },
                    @{ resource = 'trees'; suffix = "/trees/$('a' * 40)?"
                        pathId = 'sha1'; raw = $false }
                )) {
                $routeParts = @("project=$($config.projectName)",
                    "repositoryId=$($config.repositoryId)")
                if ($route.pathId) {
                    $routeParts += "$($route.pathId)=$('a' * 40)"
                }
                $url = & $intakeModule {
                    param($Org, $Project, $Resource, $Parts, $Query)
                    Get-IntakeBearerRoute $Org $Project 'git' $Resource `
                        $Parts $Query
                } 'example-org' $config.projectName $route.resource `
                    $routeParts $route.query
                $response = & $intakeModule {
                    param($Client, $Bearer, $Url, $Raw)
                    Invoke-IntakeBearerGet $Client $Bearer $Url `
                        ([DateTime]::UtcNow.AddSeconds(5)) 65536 -Raw:$Raw
                } $client $token $url $route.raw
                if ($route.raw) {
                    [Text.Encoding]::UTF8.GetString($response.bytes) |
                        Should -Be 'synthetic bytes'
                } else {
                    $response.Count | Should -Be 1
                }
                $url | Should -Match ([regex]::Escape($route.suffix))
            }
            $handler.Paths.Count | Should -Be 19
            @($handler.Tokens | Where-Object { $_ -cne $token }).Count |
                Should -Be 0
            $handler.Paths[0] | Should -Match '/_apis/connectionData\?'
            $handler.Paths[1] | Should -Match '/_apis/graph/users/'
            $handler.Paths[2] | Should -Match '/_apis/graph/storagekeys/'
            $handler.Paths[3] | Should -Match '/_apis/projects/ExampleProject\?'
            $handler.Paths[4] | Should -Match '/_apis/git/repositories/1111'
            $handler.Paths[5] | Should -Match '/_apis/git/repositories/.*/pullRequests\?'
            $handler.Paths[6] | Should -Match '/pullRequests/7/threads\?'
            $handler.Paths[11] | Should -Match '/pullRequests/7/iterations/1/changes\?'
            $handler.Paths[12] | Should -Match '/pullRequests/7\?'
            $handler.Paths[13] | Should -Match '/pullRequests/7/iterations\?'
            $handler.Paths[16] | Should -Match '/items\?'
            $handler.Paths[17] | Should -Match '/commits/'
            $handler.Paths[18] | Should -Match '/trees/'
        }
        finally { $client.Dispose() }
    }
    It 'proves a selected PR project graph through one bearer and rejects broken HTTP evidence' {
        $config = Get-Content (Join-Path $repo 'samples\active-pr-intake.config.json') `
            -Raw | ConvertFrom-Json -AsHashtable
        $config.schemaVersion = 2
        $config.principalProof = 'aad-graph-storage-key-v1'
        $config.expectedAccount.descriptor = 'aad.synthetic'
        $config.expectedAccount.principalName = 'service@example.invalid'
        $config.expectedAccount.Remove('uniqueName')
        $config.enabled = $true
        $config.projectEvidence.enabled = $true
        $source = "using Microsoft.VisualStudio.TestTools.UnitTesting;`n" +
            "[TestClass]`nclass Example {}`n"
        $project = '<Project><PropertyGroup><IsTestProject>true</IsTestProject>' +
            '</PropertyGroup><ItemGroup><Compile Include="Example.cs"/>' +
            '</ItemGroup></Project>'
        $sourceId = Get-BoundGitObjectId 'blob' (
            [Text.Encoding]::UTF8.GetBytes($source))
        $projectId = Get-BoundGitObjectId 'blob' (
            [Text.Encoding]::UTF8.GetBytes($project))
        $testsTreeId = Get-BoundTreeId @(
            @{ mode = '100644'; name = 'Example.cs'; objectId = $sourceId },
            @{ mode = '100644'; name = 'Tests.csproj'; objectId = $projectId })
        $rootTreeId = Get-BoundTreeId @(
            @{ mode = '40000'; name = 'Tests'; objectId = $testsTreeId })
        $missingProjectTreeId = Get-BoundTreeId @(
            @{ mode = '100644'; name = 'Example.cs'; objectId = $sourceId })
        $missingProjectRootId = Get-BoundTreeId @(
            @{ mode = '40000'; name = 'Tests'; objectId = $missingProjectTreeId })
        foreach ($mode in @('complete', 'corrupt-tree', 'missing-project',
                'incomplete-changes', 'throttle-tree')) {
            $handler = [CanaryBoundGetHandler]::new()
            $handler.GraphEnabled = $true
            $handler.OmitUniqueName = $true
            $handler.SourceFile = $source
            $handler.ProjectFile = $project
            $handler.SourceObjectId = $sourceId
            $handler.ProjectObjectId = $projectId
            $handler.MissingProject = $mode -eq 'missing-project'
            $handler.RootTreeId = if ($handler.MissingProject) {
                $missingProjectRootId
            } else { $rootTreeId }
            $handler.TestsTreeId = if ($handler.MissingProject) {
                $missingProjectTreeId
            } else { $testsTreeId }
            $handler.CorruptTree = $mode -eq 'corrupt-tree'
            $handler.IncompleteChanges = $mode -eq 'incomplete-changes'
            $handler.ThrottleTree = $mode -eq 'throttle-tree'
            $client = [Net.Http.HttpClient]::new($handler)
            $token = 'b' * 100
            try {
                $provider = New-ActivePrAzureDevOpsProvider -Config $config `
                    -BearerToken $token -BoundClient $client -VerifyReadPrincipal
                $identity = & $provider Identity @{ timeoutMilliseconds = 5000 }
                $identity.Contains('uniqueName') | Should -BeFalse
                $head = & $provider Head @{ pullRequestId = 7
                    remainingReads = 30; timeoutMilliseconds = 5000 }
                $head.status | Should -Be 'active'
                $head.isDraft | Should -BeFalse
                $head.targetRef | Should -Be 'refs/heads/master'
                $changeRequest = @{ pullRequestId = 7; iterationId = $head.iterationId
                    sourceCommit = $head.sourceCommit
                    targetCommit = $head.targetCommit
                    commonCommit = $head.commonCommit
                    includeEvaluationFiles = $true
                    includeProjectEvidence = $true
                    remainingReads = 30; timeoutMilliseconds = 5000 }
                if ($mode -in @('incomplete-changes', 'throttle-tree')) {
                    { & $provider Changes $changeRequest } | Should -Throw $(if (
                            $mode -eq 'incomplete-changes') {
                            '*change-list-truncated*'
                        } else { '*read-throttled*' })
                } else {
                    $changes = & $provider Changes $changeRequest
                    $changes.changedFiles | Should -Be 1
                    $changes.evaluationFiles[0].objectId | Should -Be $sourceId
                    if ($mode -eq 'complete') {
                        $changes.projectEvidence.complete | Should -BeTrue
                        $changes.projectEvidence.rootTreeId |
                            Should -Be $rootTreeId
                        $changes.projectEvidence.files[0].status |
                            Should -Be 'complete'
                        $graph = $changes.evaluationFiles[0].projectEvidence
                        $graph.sourceCommit | Should -Be $head.sourceCommit
                        $graph.objectId | Should -Be $sourceId
                        $graph.projects[0].path |
                            Should -Be '/Tests/Tests.csproj'
                        $graph.projects[0].isTestProject | Should -BeTrue
                    } else {
                        $changes.projectEvidence.complete | Should -BeFalse
                        $changes.projectEvidence.files[0].status |
                            Should -Be 'unknown'
                        $changes.evaluationFiles[0].Contains(
                            'projectEvidence') | Should -BeFalse
                        if ($mode -eq 'missing-project') {
                            $changes.projectEvidence.rootTreeId |
                                Should -Be $missingProjectRootId
                        }
                    }
                    $finalHead = & $provider Head @{ pullRequestId = 7
                        remainingReads = 30; timeoutMilliseconds = 5000 }
                    $finalHead.sourceCommit | Should -Be $head.sourceCommit
                }
                @($handler.Tokens | Where-Object { $_ -cne $token }).Count |
                    Should -Be 0
                @($handler.Paths | Where-Object {
                        $_ -notlike 'https://dev.azure.com/example-org/*' -and
                        $_ -notlike 'https://vssps.dev.azure.com/example-org/*'
                    }).Count | Should -Be 0
                if ($mode -eq 'complete') {
                    @($handler.Paths | Where-Object {
                            $_ -match '/trees/'
                        }).Count | Should -Be 2
                    @($handler.Paths | Where-Object {
                            $_ -match '/items\?'
                        }).Count | Should -Be 2
                }
            }
            finally { $client.Dispose() }
        }
    }
    It 'rejects missing-alias drift and storage mismatch before inventory, and stops on throttle' {
        $config = Get-Content (Join-Path $repo 'samples\active-pr-intake.config.json') `
            -Raw | ConvertFrom-Json -AsHashtable
        $config.schemaVersion = 2
        $config.principalProof = 'aad-graph-storage-key-v1'
        $config.expectedAccount.descriptor = 'aad.synthetic'
        $config.expectedAccount.principalName = 'service@example.invalid'
        $config.enabled = $true
        foreach ($mode in @('missing-alias', 'storage-drift', 'throttle',
                'ref-drift', 'oversize')) {
            $handler = [CanaryBoundGetHandler]::new()
            $handler.OmitUniqueName = $mode -eq 'missing-alias'
            $handler.DriftStorageKey = $mode -eq 'storage-drift'
            $handler.ThrottleInventory = $mode -eq 'throttle'
            $handler.DriftRef = $mode -eq 'ref-drift'
            $handler.TooLarge = $mode -eq 'oversize'
            $client = [Net.Http.HttpClient]::new($handler)
            try {
                $provider = New-ActivePrAzureDevOpsProvider -Config $config `
                    -BearerToken ('b' * 100) -BoundClient $client -VerifyReadPrincipal
                if ($mode -eq 'throttle') {
                    [void](& $provider Identity @{ timeoutMilliseconds = 5000 })
                    { & $provider ListPage @{ skip = 0; top = 50
                            timeoutMilliseconds = 5000 } } |
                        Should -Throw '*read-throttled*'
                    $handler.Paths.Count | Should -Be 4
                } elseif ($mode -eq 'ref-drift') {
                    [void](& $provider Identity @{ timeoutMilliseconds = 5000 })
                    { & $provider Head @{ pullRequestId = 7
                            remainingReads = 10; timeoutMilliseconds = 5000 } } |
                        Should -Throw '*head-inconsistent*'
                    $handler.Paths.Count | Should -Be 6
                } elseif ($mode -eq 'oversize') {
                    { & $provider Identity @{ timeoutMilliseconds = 5000 } } |
                        Should -Throw '*byte-budget*'
                    $handler.Paths.Count | Should -Be 1
                } else {
                    { & $provider Identity @{ timeoutMilliseconds = 5000 } } |
                        Should -Throw '*account-mismatch*'
                    $handler.Paths.Count | Should -BeLessOrEqual 3
                }
            }
            finally { $client.Dispose() }
        }
    }
}
