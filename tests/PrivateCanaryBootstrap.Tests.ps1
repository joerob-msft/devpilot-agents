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
    public bool DelayHint = false;
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
        if (DelayHint) {
            response.Headers.Add("x-ms-ratelimit-delay", "0.5");
        }
        if (BudgetRemaining != null) {
            response.Headers.Add("x-ms-ratelimit-remaining-resource",
                BudgetRemaining);
            response.Headers.Add("x-ms-ratelimit-limit-resource", "100");
            response.Headers.Add("x-ms-ratelimit-reset-resource", "1");
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
    public bool DriftGraphUpn = false;
    public bool ThrottleInventory = false;
    public bool ServiceUnavailableInventory = false;
    public bool ThrottleHintInventory = false;
    public bool DelayHintInventory = false;
    public string InventoryRemaining = null;
    public bool MissingInventory = false;
    public bool TooLarge = false;
    public bool DriftRef = false;
    public bool HistoricSourceCommit = false;
    public bool HistoricTargetCommit = false;
    public bool AdvancedTargetRef = false;
    public bool MalformedTargetRef = false;
    public bool WrongRepository = false;
    public bool Retarget = false;
    public bool GraphEnabled = false;
    public bool CorruptTree = false;
    public bool MissingProject = false;
    public bool ThrottleTree = false;
    public bool ThrottleGraphStorage = false;
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
            body = "{\"descriptor\":\"aad.synthetic\",\"subjectKind\":\"user\",\"principalName\":\"" +
                (DriftGraphUpn ? "other@example.invalid" : "service@example.invalid") + "\"}";
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
            body = "{\"pullRequestId\":7,\"status\":\"active\",\"isDraft\":false,\"sourceRefName\":\"refs/heads/feature\",\"targetRefName\":\"refs/heads/" +
                (Retarget ? "release" : "master") + "\",\"repository\":{\"id\":\"" +
                (WrongRepository ? "99999999-9999-9999-9999-999999999999" :
                    "11111111-1111-1111-1111-111111111111") +
                "\",\"project\":{\"id\":\"22222222-2222-2222-2222-222222222222\"}},\"lastMergeSourceCommit\":{\"commitId\":\"" +
                new string(HistoricSourceCommit ? 'd' : 'a', 40) +
                "\"},\"lastMergeTargetCommit\":{\"commitId\":\"" +
                new string(HistoricTargetCommit ? 'e' : 'b', 40) + "\"}}";
        } else if (path.EndsWith("/pullRequests/7/iterations")) {
            body = "{\"value\":[{\"id\":1,\"sourceRefCommit\":{\"commitId\":\"" +
                new string('a', 40) + "\"},\"targetRefCommit\":{\"commitId\":\"" +
                new string('b', 40) + "\"},\"commonRefCommit\":{\"commitId\":\"" +
                new string('c', 40) + "\"}}]}";
        } else if (path.EndsWith("/refs")) {
            var feature = request.RequestUri.Query.Contains("feature");
            body = "{\"value\":[{\"name\":\"refs/heads/" +
                (feature ? "feature" : "master") + "\",\"objectId\":\"" +
                (MalformedTargetRef && !feature ? "not-a-commit" :
                    new string(DriftRef ? 'f' :
                        (feature ? 'a' : (AdvancedTargetRef ? 'e' : 'b')), 40)) +
                "\"}]}";
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
            (ThrottleGraphStorage && path.EndsWith("/graph/storagekeys/aad.synthetic")) ||
            (ThrottleTree && path.Contains("/trees/"))
                ? (HttpStatusCode)429 :
            ServiceUnavailableInventory && path.EndsWith("/pullRequests")
                ? HttpStatusCode.ServiceUnavailable :
            MissingInventory && path.EndsWith("/pullRequests")
                ? HttpStatusCode.NotFound : HttpStatusCode.OK) {
            Content = new ByteArrayContent(TooLarge ? new byte[65537] :
                Encoding.UTF8.GetBytes(body))
        };
        if (ThrottleHintInventory && path.EndsWith("/pullRequests")) {
            response.Headers.RetryAfter =
                new System.Net.Http.Headers.RetryConditionHeaderValue(
                    TimeSpan.FromSeconds(1));
        }
        if (DelayHintInventory && path.EndsWith("/pullRequests")) {
            response.Headers.Add("x-ms-ratelimit-delay", "0.5");
        }
        if (InventoryRemaining != null && path.EndsWith("/pullRequests")) {
            response.Headers.Add("x-ms-ratelimit-remaining-resource",
                InventoryRemaining);
            response.Headers.Add("x-ms-ratelimit-limit-resource", "100");
            response.Headers.Add("x-ms-ratelimit-reset-resource", "1");
        }
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
            mergedPin = $script:MergedMasterPin
            ownerReviewed = $script:OwnerSourceReviewedInApprovedRepository }
    }
    $script:ownerDocument = "## Claim ownership`nSynthetic owner rule.`n" +
        "## Named parameters for Assert`nSynthetic named rule.`n" +
        "## Following`nNot part of either section.`n"
    $script:coverageDocument = (@('## Synthetic project policy') +
        @('Synthetic convention.') * 219 +
        @('Every class uses an exclusion.', '',
            'Method exclusion is redundant.', '', '## Other', 'End.')) -join "`n"
    $script:coverageDocument += "`n" + $script:ownerDocument
    $script:sourceKey = 'b' * 64
    $script:sourceSelector = [ordered]@{
        schemaVersion = 1; kind = 'private-canary-source-selector'
        organization = 'example-org'; projectName = 'ExampleSource'
        repositoryName = 'ExamplePolicyRepo'; signature = ''
    }
    $script:sourceSelector.signature = & $module {
        param($Selector, $Key)
        Get-CanarySignature $Selector $Key
    } $script:sourceSelector $script:sourceKey
    $script:sourceOrg = $script:sourceSelector.organization
    $script:sourcePrId = 17307009
    $script:discoverySelector = @{
        organization = $script:sourceOrg; projectName = 'ExampleSource'
        repositoryName = 'ExamplePolicyRepo'
    }
    $script:documentSelector = & $module { $script:DocumentPath }
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
        $script:OwnerSourceReviewedInApprovedRepository = $true
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
    $script:mergedKey = 'c' * 64
    $script:mergedEnvelope = [ordered]@{
        schemaVersion = 1; kind = 'private-reviewed-merged-master-pin'
        selectorSignature = $script:sourceSelector.signature
        pin = & $module { $script:MergedMasterPin }
        signature = ''
    }
    function Set-SyntheticMergedApproval {
        $script:mergedEnvelope.signature = & $module {
            param($Envelope, $Key)
            Get-CanarySignature $Envelope $Key
        } $script:mergedEnvelope $script:mergedKey
    }
    Set-SyntheticMergedApproval
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
            forwardMasterVisits = 0
            sourceLineage = ''
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
                if ($state.wrong -eq 'owner-content') {
                    $state.owner.Replace('Synthetic owner rule.',
                        'Changed owner rule.')
                } elseif ($state.wrong -eq 'named-content') {
                    $state.owner.Replace('Synthetic named rule.',
                        'Changed named rule.')
                } else { $state.owner }
            } elseif ($request.commit -ceq $state.head -and
                $state.wrong -eq 'candidate-content') {
                $state.coverage + ' changed on reviewed source'
            } elseif ($request.commit -ceq ('d' * 40) -and
                $state.wrong -eq 'merge-content') {
                $state.coverage + ' changed at merge'
            } elseif ($request.commit -ceq $state.master -and
                $state.wrong -eq 'master-content') {
                $state.coverage + ' changed on master'
            } elseif ($request.commit -ceq ('e' * 40) -and
                $state.wrong -eq 'snapshot-content') {
                $state.coverage + ' changed at recorded snapshot'
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
                    if ($request.projectName -ceq 'ExampleSource') {
                        return @{ id = $engProjectId
                            name = if ($state.wrong -eq 'source-project') {
                                'WrongSource'
                            } else { 'ExampleSource' } }
                    }
                    return @{ id = $projectId
                        name = if ($state.wrong -eq 'project') {
                            'WrongProject'
                        } else { 'ExampleProject' } }
                }
                Repository {
                    if ($request.projectName -ceq 'ExampleSource') {
                        return @{ id = if ($state.wrong -eq 'source-repo-id') {
                                'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
                            } else { $engRepoId }
                            name = if ($state.wrong -eq 'source-repo') {
                                'WrongRepo'
                            } else { 'ExamplePolicyRepo' }
                            project = @{ id = $engProjectId; name = 'ExampleSource' } }
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
                            project = @{ id = $engProjectId; name = 'ExampleSource' } }
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
                    if ($request.commit -ceq ('f' * 40)) {
                        $state.forwardMasterVisits++
                        if ($state.sourceLineage -eq 'malformed-after-proof' -and
                            $state.forwardMasterVisits -gt 1) {
                            return @{ commitId = $request.commit
                                parents = @('not-a-commit') }
                        }
                    }
                    return @{ commitId = if ($state.wrong -eq 'commit') {
                            'a' * 40
                        } else { $request.commit }
                        parents = @(if ($request.commit -ceq ('d' * 40)) {
                                if ($state.wrong -eq 'owner-no-ancestry') {
                                    'b' * 40
                                } else { $ownerCommit }
                            } elseif ($request.commit -ceq ('f' * 40) -and
                                $state.sourceLineage -ne 'non-descendant') {
                                'e' * 40
                            } else { 'd' * 40 }) }
                }
                Item {
                    if ($request.projectName -cne 'ExampleSource' -or
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
    function Get-ProvisionCase {
        $case = Get-BootstrapCase
        $case.root = Join-Path $env:USERPROFILE (
            '.copilot\private-merged-pin-' + [guid]::NewGuid().ToString('N'))
        $script:roots.Add($case.root)
        $script:roots.Add("$($case.root).staging")
        return $case
    }
    function Invoke-ProvisionCase($Case, $Selector = $script:discoverySelector,
        $PullRequestId = $script:sourcePrId,
        $DocumentPath = $script:documentSelector) {
        & (Get-Module DevPilot.ActivePrCanary) {
            param($Root, $Repository, $Selector, $PullRequestId,
                $DocumentPath, $Provider)
            Invoke-CanaryMergedPinProvisionCore -StateRoot $Root `
                -RepositoryRoot $Repository -SourceSelector $Selector `
                -SourcePullRequestId $PullRequestId `
                -DocumentPath $DocumentPath `
                -ExpectedAccountUniqueName 'service@example.invalid' `
                -Read $Provider -Run
        } $Case.root $repo $Selector $PullRequestId $DocumentPath `
            $Case.provider
    }
    function Invoke-BootstrapCase($Case, [switch]$CoverageOnly) {
        Invoke-PrivateCanaryBootstrap -Organization $script:sourceOrg `
            -ProjectName 'ExampleProject' -RepositoryName 'ExampleRepo' `
            -SourceSelector $script:sourceSelector `
            -SourceSelectorKey $script:sourceKey `
            -MergedPinEnvelope $script:mergedEnvelope `
            -MergedPinKey $script:mergedKey `
            -ExpectedAccountUniqueName 'service@example.invalid' `
            -StateRoot $Case.root -RepositoryRoot $repo -Read $Case.provider `
            -Mode $(if ($CoverageOnly) { 'CoverageOnly' } else { 'FourRule' }) -Run
    }
    function Get-RegistryCase {
        param([switch]$MissingUniqueName, [switch]$CoverageOnly)
        $case = Get-BootstrapCase
        if ($MissingUniqueName) { $case.state.wrong = 'missing-unique-name' }
        [void](Invoke-BootstrapCase $case -CoverageOnly:$CoverageOnly)
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
            -Read $InputCase.case.provider `
            -SourceSelector $script:sourceSelector `
            -SourceSelectorKey $script:sourceKey `
            -MergedPinEnvelope $script:mergedEnvelope `
            -MergedPinKey $script:mergedKey `
            -ExpectedAccountUniqueName 'service@example.invalid' `
            -Mode $(if ($InputCase.sources.mode -ceq 'coverage-only') {
                    'CoverageOnly'
                } else { 'FourRule' }) -Run
    }
    function Get-SignedIntakeCase {
        param([switch]$Code, [switch]$MissingUniqueName,
            [switch]$CoverageOnly, [switch]$RedundantCode)
        if ($RedundantCode -and -not $Code) {
            throw 'redundant test requires C#'
        }
        $inputCase = Get-RegistryCase -MissingUniqueName:$MissingUniqueName `
            -CoverageOnly:$CoverageOnly
        $root = $inputCase.case.root + '-signed'
        $script:roots.Add($root)
        $state = @{
            calls = [Collections.Generic.List[string]]::new()
            wrong = ''
            visits = 0
            currentTarget = 'd' * 40
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
        $content = if ($RedundantCode) {
            (@('using Microsoft.VisualStudio.TestTools.UnitTesting;',
                'using System.Diagnostics.CodeAnalysis;',
                '[TestClass]', '[ExcludeFromCodeCoverage]', 'class Example {',
                '    [TestMethod]', '    [ExcludeFromCodeCoverage]',
                '    public void Check() {}', '}') -join "`n") + "`n"
        } elseif ($Code) {
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
        $state.lines = if ($RedundantCode) { 9 } elseif ($Code) { 3 } else { 1 }
        $state.code = [bool]$Code
        $provider = {
            param($op, $request)
            $state.calls.Add($op) | Out-Null
            switch -CaseSensitive ($op) {
                Identity {
                    $identity = @{ id = $config.expectedAccount.id
                        descriptor = $config.expectedAccount.descriptor
                        principalName = if ($state.wrong -eq 'identity-upn') {
                            'other@example.invalid'
                        } else { 'service@example.invalid' } }
                    $identityReads = @($state.calls | Where-Object {
                            $_ -eq 'Identity'
                        }).Count
                    if ((-not $MissingUniqueName -and
                            $state.wrong -ne 'alias-added') -or
                        ($state.wrong -eq 'alias-added' -and
                            $identityReads -gt 1)) {
                        $identity.uniqueName = if ($state.wrong -eq 'identity-alias') {
                            'other@example.invalid'
                        } else { 'service@example.invalid' }
                    }
                    if ($state.wrong -eq 'alias-removed' -and
                        $identityReads -gt 1) {
                        $identity.Remove('uniqueName')
                    }
                    return $identity
                }
                ListPage {
                    if ($state.wrong -eq 'inaccessible-page') {
                        throw 'private route and account must not escape'
                    }
                    if ($request.skip -ne 0 -or $request.top -ne 52 -or
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
                    $head = @{ pullRequestId = $id
                        repositoryId = $config.repository.id
                        projectId = $config.projectId
                        status = 'active'; isDraft = $false
                        sourceRef = 'refs/heads/feature'
                        targetRef = if ($state.wrong -eq 'retarget') {
                            'refs/heads/release'
                        } else { $row.targetRef }
                        sourceCommit = if ($state.wrong -eq 'stale-head' -and
                            $state.visits -gt 1) { 'f' * 40 } else { 'a' * 40 }
                        targetCommit = 'b' * 40
                        commonCommit = if ($state.wrong -eq 'iteration-baseline-drift' -and
                            $state.visits -gt 1) { 'f' * 40 } else { 'c' * 40 }
                        iterationId = if ($state.wrong -eq 'iteration-baseline-drift' -and
                            $state.visits -gt 1) { 2 } else { 1 } }
                    if ($CoverageOnly) {
                        $head.currentTargetCommit = if (
                            $state.wrong -eq 'invalid-live-target') {
                            'not-a-sha'
                        } elseif (
                            ($state.wrong -eq 'target-head-drift' -and
                                $state.visits -gt 1) -or
                            ($state.wrong -eq 'target-runner-drift' -and
                                $state.visits -gt 2)) {
                            'e' * 40
                        } else { $state.currentTarget }
                    }
                    return $head
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
                        baseCommit = if ($state.wrong -eq 'baseline-drift') {
                            'f' * 40
                        } else { $request.commonCommit }
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
    function Invoke-SignedIntakeCase($Case, [ref]$FailureDiagnostic) {
        $diagnosticArgs = @{}
        if ($FailureDiagnostic) {
            $diagnosticArgs.FailureDiagnostic = $FailureDiagnostic
        }
        Invoke-PrivateCanarySignedIntake -ProviderConfig $Case.input.config `
            -ApprovedSources $Case.input.sources -StateRoot $Case.root `
            -RepositoryRoot $repo -CanaryPullRequestIds @(17007699, 17109075) `
            -SourceSelector $script:sourceSelector `
            -SourceSelectorKey $script:sourceKey `
            -MergedPinEnvelope $script:mergedEnvelope `
            -MergedPinKey $script:mergedKey `
            -ExpectedAccountUniqueName 'service@example.invalid' `
            -Read $Case.read -Provider $Case.provider `
            @diagnosticArgs `
            -Mode $(if ($Case.input.sources.mode -ceq 'coverage-only') {
                    'CoverageOnly'
                } else { 'FourRule' }) -Run
    }
    function Invoke-RunnerCase($Case) {
        Invoke-PrivateCanaryEvaluation -StateRoot $Case.root `
            -SourceSelector $script:sourceSelector `
            -SourceSelectorKey $script:sourceKey `
            -MergedPinEnvelope $script:mergedEnvelope `
            -MergedPinKey $script:mergedKey `
            -ExpectedAccountUniqueName 'service@example.invalid' `
            -RepositoryRoot $repo -Read $Case.read -Provider $Case.provider `
            -Mode $(if ($Case.input.sources.mode -ceq 'coverage-only') {
                    'CoverageOnly'
                } else { 'FourRule' }) -Run
    }
    function New-RunnerThread($Case, [int]$Id, [string]$Body,
        [switch]$Outdated, [int]$Line = 3) {
        return @{
            id = $Id; status = 'active'
            comments = @(@{ id = 1; author = $Case.input.config.expectedAccount
                    commentType = 'text'; content = $Body })
            threadContext = @{ filePath = $Case.state.path
                rightFileStart = @{ line = $Line }
                rightFileEnd = @{ line = $Line } }
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
        $script:OwnerSourceReviewedInApprovedRepository = $Previous.ownerReviewed
    } $script:old
    foreach ($root in $script:roots) {
        if (Test-Path -LiteralPath $root) {
            Remove-Item -LiteralPath $root -Recurse -Force
        }
    }
}
Describe 'Read-only private canary input bootstrap' {
    Describe 'User-authorized source-only private pin provisioner' {
        It 'defaults off without identity, ADO, or files' {
            $c = Get-ProvisionCase
            $result = Invoke-PrivateCanaryMergedPinProvision `
                -StateRoot $c.root -RepositoryRoot $repo
            $result.state | Should -Be 'disabled'
            $result.privateFilesWritten | Should -Be 0
            $c.state.reads.Count | Should -Be 0
            Test-Path -LiteralPath $c.root | Should -BeFalse
            { Invoke-PrivateCanaryMergedPinProvision `
                    -StateRoot $c.root -RepositoryRoot $repo `
                    -Read $c.provider -Run } | Should -Throw
            $c.state.reads.Count | Should -Be 0
            $json = & (Join-Path $repo 'tools\Provision-PrivateCanaryMergedPin.ps1')
            ($json | ConvertFrom-Json -AsHashtable).state | Should -Be 'disabled'
        }
        It 'rejects malformed route, wrong PR and wrong document before any GET or state' {
            $c = Get-ProvisionCase
            $selector = [ordered]@{}
            foreach ($field in $script:discoverySelector.Keys) {
                $selector[$field] = $script:discoverySelector[$field]
            }
            $selector['signature'] = 'untrusted'
            { Invoke-ProvisionCase $c $selector } |
                Should -Throw '*source-selector-invalid*'
            [void]$selector.Remove('signature')
            $selector.projectName = '../WrongSource'
            { Invoke-ProvisionCase $c $selector } |
                Should -Throw '*source-selector-invalid*'
            { Invoke-ProvisionCase $c $script:discoverySelector 1 } |
                Should -Throw '*source-selector-invalid*'
            { Invoke-ProvisionCase $c $script:discoverySelector `
                    $script:sourcePrId '/wrong.md' } |
                Should -Throw '*source-selector-invalid*'
            $c.state.reads.Count | Should -Be 0
            Test-Path -LiteralPath $c.root | Should -BeFalse
        }
        It 'rejects a plausible wrong source route after bounded reads without state' {
            $c = Get-ProvisionCase
            $selector = [ordered]@{}
            foreach ($field in $script:discoverySelector.Keys) {
                $selector[$field] = $script:discoverySelector[$field]
            }
            $selector.projectName = 'OtherSource'
            { Invoke-ProvisionCase $c $selector } | Should -Throw
            $c.state.reads.Count | Should -BeGreaterThan 0
            Test-Path -LiteralPath $c.root | Should -BeFalse
        }
        It 'keeps the new root absent throughout all source and final identity reads' {
            $c = Get-ProvisionCase
            $original = $c.provider
            $root = $c.root
            $observed = [Collections.Generic.List[string]]::new()
            $c.provider = {
                param($op, $request)
                if ((Test-Path -LiteralPath $root) -or
                    (Test-Path -LiteralPath "$root.staging")) {
                    $observed.Add($op)
                }
                & $original $op $request
            }.GetNewClosure()
            $result = Invoke-ProvisionCase $c
            $result.state | Should -Be 'private-source-pin-prepared-unactivated'
            $observed.Count | Should -Be 0
            $c.state.reads[-1] | Should -Be 'GraphStorageKey'
        }
        It 'prepares only a synthetic ACL-private unactivated pin after final proof' {
            $c = Get-ProvisionCase
            $result = Invoke-ProvisionCase $c
            $result.state | Should -Be 'private-source-pin-prepared-unactivated'
            $result.privateFilesWritten | Should -Be 4
            $result.providerWrites | Should -Be 0
            $result.providerReads | Should -Be $c.state.reads.Count
            @($c.state.reads | Where-Object { $_ -eq 'GraphStorageKey' }).Count |
                Should -Be 2
            $selectorKeyPath = Join-Path $c.root 'source-selector.key'
            $selectorPath = Join-Path $c.root 'source-selector.json'
            $keyPath = Join-Path $c.root 'merged-pin.key'
            $pinPath = Join-Path $c.root 'merged-pin.json'
            [void](Assert-AgentTrustedFile $selectorKeyPath -AllowedRoot $c.root -Private)
            [void](Assert-AgentTrustedFile $selectorPath -AllowedRoot $c.root -Private)
            [void](Assert-AgentTrustedFile $keyPath -AllowedRoot $c.root -Private)
            [void](Assert-AgentTrustedFile $pinPath -AllowedRoot $c.root -Private)
            $source = Read-CanaryPrivateSourceSelector `
                -SelectorPath $selectorPath -KeyPath $selectorKeyPath `
                -RepositoryRoot $repo
            $source.selector.organization | Should -Be $script:sourceOrg
            $source.selector.projectName | Should -Be $script:discoverySelector.projectName
            $source.selector.repositoryName |
                Should -Be $script:discoverySelector.repositoryName
            $source.key | Should -Not -Be $script:sourceKey
            $envelope = Get-Content $pinPath -Raw |
                ConvertFrom-Json -AsHashtable
            $envelope.pin.Count | Should -Be 10
            $envelope.selectorSignature |
                Should -Be $source.selector.signature
            $loaded = Read-CanaryPrivateMergedPin -PinPath $pinPath `
                -KeyPath $keyPath -RepositoryRoot $repo `
                -SourceSelector $source.selector
            $loaded.envelope.pin.mergeCommit | Should -Be ('d' * 40)
            $loaded.key | Should -Not -Be $source.key
            $module = Get-Module DevPilot.ActivePrCanary
            $expected = & $module { $script:MergedMasterPin }
            (ConvertTo-AgentCanonicalJson -InputObject $loaded.envelope.pin) |
                Should -Be (ConvertTo-AgentCanonicalJson -InputObject $expected)
            (ConvertTo-Json -InputObject $result) |
                Should -Not -Match 'ExampleSource|service@example.invalid|private-merged-pin|mergeCommit|aad.synthetic|source-selector'
            Test-Path -LiteralPath "$($c.root).staging" | Should -BeFalse
        }
        It 'requires an in-process selector object and rejects wrapper mismatch before account access' {
            $c = Get-ProvisionCase
            $sourceInput = @{
                organization = $script:sourceOrg
                projectName = 'ExampleSource'
                repositoryName = 'ExamplePolicyRepo'
                pullRequestId = 1
                documentPath = $script:documentSelector
            }
            { & (Join-Path $repo 'tools\Provision-PrivateCanaryMergedPin.ps1') `
                    -StateRoot $c.root -SourceInput $sourceInput -Run } |
                Should -Throw '*source-selector-invalid*'
            [void]$sourceInput.Remove('repositoryName')
            { & (Join-Path $repo 'tools\Provision-PrivateCanaryMergedPin.ps1') `
                    -StateRoot $c.root -SourceInput $sourceInput -Run } |
                Should -Throw '*source-selector-invalid*'
            try {
                & (Join-Path $repo 'tools\Provision-PrivateCanaryMergedPin.ps1') `
                    -StateRoot $c.root -SourceInput 'synthetic-route' -Run
                throw 'expected invalid source input'
            }
            catch {
                $_.Exception.Message | Should -Be 'source-selector-invalid'
            }
            $c.state.reads.Count | Should -Be 0
            Test-Path -LiteralPath $c.root | Should -BeFalse
        }
        It 'leaves no root on active, changed, unproved, identity or throttle failure' {
            foreach ($failure in @('active-pr', 'candidate-content',
                    'merge-content',
                    'master-content', 'no-ancestry', 'graph-upn',
                    'master-ref-drift', 'throttle')) {
                $c = Get-ProvisionCase
                if ($failure -eq 'throttle') {
                    $original = $c.provider
                    $c.provider = {
                        param($op, $request)
                        if ($op -ceq 'RawItem') { throw 'read-throttled' }
                        & $original $op $request
                    }.GetNewClosure()
                } else { $c.state.wrong = $failure }
                { Invoke-ProvisionCase $c } | Should -Throw -Because $failure
                Test-Path -LiteralPath $c.root | Should -BeFalse
                Test-Path -LiteralPath "$($c.root).staging" | Should -BeFalse
                @($c.state.reads | Where-Object {
                        $_ -in @('Write', 'Post', 'ListPage')
                    }).Count | Should -Be 0
            }
        }
        It 'never uses an existing or repository-contained root and cleans a partial write' {
            $c = Get-ProvisionCase
            New-Item -ItemType Directory -Path $c.root | Out-Null
            { Invoke-ProvisionCase $c } |
                Should -Throw '*merged-master-private-root-invalid*'
            Test-Path -LiteralPath $c.root | Should -BeTrue
            $c.state.reads.Count | Should -Be 0
            $alias = Join-Path $c.root (
                '..\' + (Split-Path $c.root -Leaf))
            $c.root = $alias
            { Invoke-ProvisionCase $c } |
                Should -Throw '*merged-master-private-root-invalid*'
            Test-Path -LiteralPath ([IO.Path]::GetFullPath($alias)) |
                Should -BeTrue
            $c.state.reads.Count | Should -Be 0
            $c.root = Join-Path $repo (
                'private-merged-pin-' + [guid]::NewGuid().ToString('N'))
            { Invoke-ProvisionCase $c } |
                Should -Throw '*merged-master-private-root-invalid*'
            $c.state.reads.Count | Should -Be 0
            $c = Get-ProvisionCase
            Mock Write-CanaryPrivateFile -ModuleName DevPilot.ActivePrCanary {
                throw 'synthetic-write-failed'
            } -ParameterFilter { $Path -like '*merged-pin.json' }
            { Invoke-ProvisionCase $c } |
                Should -Throw '*merged-master-private-provision-failed*'
            $c.state.reads.Count | Should -BeGreaterThan 0
            Test-Path -LiteralPath $c.root | Should -BeFalse
            Test-Path -LiteralPath "$($c.root).staging" | Should -BeFalse
        }
        It 'cleans a newly staged selector write failure without publishing any files' {
            $c = Get-ProvisionCase
            Mock Write-CanaryPrivateFile -ModuleName DevPilot.ActivePrCanary {
                throw 'synthetic-write-failed'
            } -ParameterFilter { $Path -like '*source-selector.json' }
            { Invoke-ProvisionCase $c } |
                Should -Throw '*merged-master-private-provision-failed*'
            $c.state.reads.Count | Should -BeGreaterThan 0
            Test-Path -LiteralPath $c.root | Should -BeFalse
            Test-Path -LiteralPath "$($c.root).staging" | Should -BeFalse
        }
    }
    It 'discovers only sanitized unapproved metadata with no pin, state, or writes' {
        $c = Get-BootstrapCase
        $module = Get-Module DevPilot.ActivePrCanary
        $syntheticPin = & $module { $script:MergedMasterPin }
        try {
            & $module { $script:MergedMasterPin = $null }
            $result = Invoke-CanaryMergedMasterDiscovery `
                -Organization $script:sourceOrg `
                -ExpectedAccountUniqueName 'service@example.invalid' `
                -SourceSelector $script:discoverySelector `
                -SourcePullRequestId $script:sourcePrId `
                -RepositoryRoot $repo -Read $c.provider -Run
            $result.state | Should -Be 'discovered-merged-source-no-state'
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
        foreach ($failure in @('source-project', 'source-repo',
                'source-repo-id',
                'active-pr', 'candidate-content',
                'merge-content', 'master-content', 'no-ancestry',
                'master-ref-drift', 'graph-upn')) {
            $c = Get-BootstrapCase
            $c.state.wrong = $failure
            { Invoke-CanaryMergedMasterDiscovery -Organization $script:sourceOrg `
                    -ExpectedAccountUniqueName 'service@example.invalid' `
                    -SourceSelector $script:discoverySelector `
                    -SourcePullRequestId $script:sourcePrId `
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
            $script:mergedEnvelope.pin = $originalPin
            Set-SyntheticMergedApproval
        }
    }
    It 'rejects independently wrong section, line, and declaration pins' {
        $module = Get-Module DevPilot.ActivePrCanary
        foreach ($field in @('sectionHash', 'classLineHash',
                'redundantLineHash', 'classDeclarationDigest',
                'redundantDeclarationDigest')) {
            $c = Get-BootstrapCase
            $originalPin = & $module { @{} + $script:MergedMasterPin }
            try {
                & $module {
                    param($Name)
                    $script:MergedMasterPin[$Name] = 'v1:sha256:' + 'a' * 64
                } $field
                Set-SyntheticMergedApproval
                { Invoke-BootstrapCase $c } |
                    Should -Throw '*merged-master-declaration-drift*' -Because $field
                Test-Path -LiteralPath $c.root | Should -BeFalse
            }
            finally {
                & $module { param($Pin) $script:MergedMasterPin = $Pin } $originalPin
                $script:mergedEnvelope.pin = $originalPin
                Set-SyntheticMergedApproval
            }
        }
    }
    It 'refuses a different organization before any GET or state' {
        $c = Get-BootstrapCase
        { Invoke-CanaryMergedMasterDiscovery -Organization 'wrong-org' `
                -ExpectedAccountUniqueName 'service@example.invalid' `
                -SourceSelector $script:discoverySelector `
                -SourcePullRequestId $script:sourcePrId `
                -RepositoryRoot $repo -Read $c.provider -Run } |
            Should -Throw '*source-selector-invalid*'
        $c.state.reads.Count | Should -Be 0
        Test-Path -LiteralPath $c.root | Should -BeFalse
    }
    It 'rejects a malformed selector or wrong PR before a GET or state' {
        $c = Get-BootstrapCase
        $selector = @{} + $script:discoverySelector
        $selector.projectName = '..'
        { Invoke-CanaryMergedMasterDiscovery -Organization $script:sourceOrg `
                -ExpectedAccountUniqueName 'service@example.invalid' `
                -SourceSelector $selector -SourcePullRequestId $script:sourcePrId `
                -RepositoryRoot $repo -Read $c.provider -Run } |
            Should -Throw '*source-selector-invalid*'
        { Invoke-CanaryMergedMasterDiscovery -Organization $script:sourceOrg `
                -ExpectedAccountUniqueName 'service@example.invalid' `
                -SourceSelector $script:discoverySelector `
                -SourcePullRequestId 1 `
                -RepositoryRoot $repo -Read $c.provider -Run } |
            Should -Throw '*source-selector-invalid*'
        $c.state.reads.Count | Should -Be 0
        Test-Path -LiteralPath $c.root | Should -BeFalse
    }
    It 'fails closed on a plausible wrong source route after bounded reads, without state' {
        $c = Get-BootstrapCase
        $wrong = @{} + $script:discoverySelector
        $wrong.projectName = 'WrongSource'
        { Invoke-CanaryMergedMasterDiscovery -Organization $script:sourceOrg `
                -ExpectedAccountUniqueName 'service@example.invalid' `
                -SourceSelector $wrong -SourcePullRequestId $script:sourcePrId `
                -RepositoryRoot $repo -Read $c.provider -Run } | Should -Throw
        $c.state.reads.Count | Should -BeGreaterThan 0
        $c.state.reads.Count | Should -BeLessOrEqual 5
        Test-Path -LiteralPath $c.root | Should -BeFalse
    }
    It 'cannot load a tracked fictional sample as operator authority' {
        { Read-CanaryPrivateSourceSelector `
                -SelectorPath (Join-Path $repo `
                    'samples\private-canary-source-selector.example.json') `
                -KeyPath (Join-Path $repo `
                    'samples\private-canary-source-selector.example.json') `
                -RepositoryRoot $repo } |
            Should -Throw '*source-selector-invalid*'
    }
    It 'rejects non-fictional private-selector samples in the hygiene check' {
        $sampleRoot = Join-Path $TestDrive 'samples'
        [void](New-Item -ItemType Directory -Path $sampleRoot -Force)
        $example = Join-Path $repo `
            'samples\private-canary-source-selector.example.json'
        $target = Join-Path $sampleRoot `
            'private-canary-source-selector.example.json'
        Copy-Item -LiteralPath $example -Destination $target
        $check = Join-Path $repo 'tools\Test-NoEmployerSpecifics.ps1'
        $null = & pwsh -NoProfile -File $check -RepoRoot $TestDrive
        $LASTEXITCODE | Should -Be 0
        $bad = Get-Content -LiteralPath $target -Raw |
            ConvertFrom-Json -AsHashtable
        $bad.projectName = 'UnexpectedSource'
        $bad | ConvertTo-Json | Set-Content -LiteralPath $target
        $output = & pwsh -NoProfile -File $check -RepoRoot $TestDrive
        $LASTEXITCODE | Should -Be 1
        ($output -join "`n") | Should -Match `
            'Private selector sample must be fictional'
    }
    It 'rejects a production-looking bare organization or URL in generic samples' {
        $sampleRoot = Join-Path $TestDrive 'samples'
        [void](New-Item -ItemType Directory -Path $sampleRoot -Force)
        $check = Join-Path $repo 'tools\Test-NoEmployerSpecifics.ps1'
        $target = Join-Path $sampleRoot 'sample.config.json'
        @{ organization = 'enterprise-tenant' } | ConvertTo-Json |
            Set-Content -LiteralPath $target
        $output = & pwsh -NoProfile -File $check -RepoRoot $TestDrive
        $LASTEXITCODE | Should -Be 1
        ($output -join "`n") | Should -Match 'Sample selectors must be fictional'
        @{ organization = ('https://dev.azure.com/' + 'enterprise-tenant') } |
            ConvertTo-Json | Set-Content -LiteralPath $target
        $output = & pwsh -NoProfile -File $check -RepoRoot $TestDrive
        $LASTEXITCODE | Should -Be 1
        ($output -join "`n") | Should -Match 'Sample selectors must be fictional'
    }
    It 'rejects legacy source URLs, API repository routes and disguised names' {
        $fixtureRoot = Join-Path $TestDrive 'legacy-url-fixture'
        $sampleRoot = Join-Path $fixtureRoot 'samples'
        [void](New-Item -ItemType Directory -Path $sampleRoot -Force)
        $check = Join-Path $repo 'tools\Test-NoEmployerSpecifics.ps1'
        $target = Join-Path $sampleRoot 'sample.config.json'
        $legacyHost = 'visualstudio.com'
        @{ sourceUrl = "https://example.$legacyHost/ExampleProject/_git/ExampleRepo" } |
            ConvertTo-Json | Set-Content -LiteralPath $target
        $null = & pwsh -NoProfile -File $check -RepoRoot $fixtureRoot
        $LASTEXITCODE | Should -Be 0
        @{ sourceUrl = "https://example.$legacyHost/_apis/git/repositories/ExampleRepo" } |
            ConvertTo-Json | Set-Content -LiteralPath $target
        $null = & pwsh -NoProfile -File $check -RepoRoot $fixtureRoot
        $LASTEXITCODE | Should -Be 0
        foreach ($url in @(
                "https://tenant.$legacyHost/Project/_git/Repo",
                "https://example.$legacyHost/ExampleProject/_apis/git/repositories/EnterpriseRepo",
                "https://example.$legacyHost/_apis/git/repositories/EnterpriseRepo",
                'https://dev.azure.com/example-org/_apis/git/repositories/EnterpriseRepo',
                'https://dev.azure.com/example-org/ExampleProject/_git/EnterpriseRepo')) {
            @{ sourceUrl = $url } | ConvertTo-Json |
                Set-Content -LiteralPath $target
            $output = & pwsh -NoProfile -File $check -RepoRoot $fixtureRoot
            $LASTEXITCODE | Should -Be 1
            ($output -join "`n") | Should -Match `
                'Sample selectors must be fictional'
        }
        @{ organization = 'example-org'; projectName = 'myServiceRepo' } |
            ConvertTo-Json | Set-Content -LiteralPath $target
        $output = & pwsh -NoProfile -File $check -RepoRoot $fixtureRoot
        $LASTEXITCODE | Should -Be 1
        ($output -join "`n") | Should -Match 'Sample selectors must be fictional'
    }
    It 'inspects nested sample JSON for org-scoped legacy source routes' {
        $fixtureRoot = Join-Path $TestDrive 'nested-url-fixture'
        $sampleRoot = Join-Path $fixtureRoot 'samples'
        $nested = Join-Path $sampleRoot 'subdir'
        [void](New-Item -ItemType Directory -Path $nested -Force)
        $target = Join-Path $nested 'sample.config.json'
        $legacyHost = 'visualstudio.com'
        @{ sourceUrl = "https://tenant.$legacyHost/_apis/git/repositories/EnterpriseRepo" } |
            ConvertTo-Json | Set-Content -LiteralPath $target
        $check = Join-Path $repo 'tools\Test-NoEmployerSpecifics.ps1'
        $output = & pwsh -NoProfile -File $check -RepoRoot $fixtureRoot
        $LASTEXITCODE | Should -Be 1
        ($output -join "`n") | Should -Match 'Sample selectors must be fictional'
        ($output -join "`n") | Should -Match 'subdir'
    }
    It 'keeps inherited Owner and Named provenance unapproved until separately reviewed' {
        $c = Get-BootstrapCase
        $module = Get-Module DevPilot.ActivePrCanary
        try {
            & $module { $script:OwnerSourceReviewedInApprovedRepository = $false }
            { Invoke-BootstrapCase $c } |
                Should -Throw '*owner-source-provenance-unreviewed*'
            $c.state.reads.Count | Should -Be 0
            Test-Path -LiteralPath $c.root | Should -BeFalse
        }
        finally {
            & $module { $script:OwnerSourceReviewedInApprovedRepository = $true }
        }
    }
    It 'refuses separate Owner ancestry and raw-source drift before private state' {
        foreach ($failure in @('owner-no-ancestry', 'owner-content',
                'named-content')) {
            $c = Get-BootstrapCase
            $c.state.wrong = $failure
            { Invoke-BootstrapCase $c } | Should -Throw -Because $failure
            Test-Path -LiteralPath $c.root | Should -BeFalse
            @($c.state.reads | Where-Object { $_ -in @('Write', 'Post') }).Count |
                Should -Be 0
        }
    }
    It 'has no public source pin and rejects missing private input before GET or state' {
        $c = Get-BootstrapCase
        $module = Get-Module DevPilot.ActivePrCanary
        $syntheticPin = & $module { $script:MergedMasterPin }
        try {
            & $module { $script:MergedMasterPin = $null }
            { Invoke-CanaryMergedMasterPreflight -Organization $script:sourceOrg `
                    -ExpectedAccountUniqueName 'service@example.invalid' `
                    -SourceSelector $script:sourceSelector `
                    -SourceSelectorKey $script:sourceKey `
                    -MergedPinEnvelope $null `
                    -MergedPinKey $script:mergedKey `
                    -RepositoryRoot $repo -Read $c.provider -Run } |
                Should -Throw '*merged-master-pin-unavailable*'
            { Invoke-PrivateCanaryBootstrap -Organization $script:sourceOrg `
                    -ProjectName 'ExampleProject' -RepositoryName 'ExampleRepo' `
                    -SourceSelector $script:sourceSelector `
                    -SourceSelectorKey $script:sourceKey `
                    -MergedPinEnvelope $null -MergedPinKey $script:mergedKey `
                    -ExpectedAccountUniqueName 'service@example.invalid' `
                    -StateRoot $c.root -RepositoryRoot $repo `
                    -Read $c.provider -Run } |
                Should -Throw '*merged-master-pin-unavailable*'
            $c.state.reads.Count | Should -Be 0
            Test-Path -LiteralPath $c.root | Should -BeFalse
        }
        finally {
            & $module { param($Pin) $script:MergedMasterPin = $Pin } $syntheticPin
        }
    }
    It 'rejects missing private files before making a GET' {
        $c = Get-BootstrapCase
        { Read-CanaryPrivateMergedPin -PinPath (Join-Path $c.root 'absent.json') `
                -KeyPath (Join-Path $c.root 'absent.key') `
                -RepositoryRoot $repo `
                -SourceSelector $script:sourceSelector } |
            Should -Throw '*merged-master-pin-unavailable*'
        $c.state.reads.Count | Should -Be 0
        Test-Path -LiteralPath $c.root | Should -BeFalse
    }
    It 'loads only an external ACL-private integrity-bound synthetic pin' {
        $c = Get-BootstrapCase
        $created = $false
        $root = Resolve-AgentTrustedRoot -Path $c.root -Kind durable-state `
            -RepositoryRoot $repo -Create -CreatedByCaller ([ref]$created)
        $created | Should -BeTrue
        $pinPath = Join-Path $root 'synthetic-merged-pin.json'
        $keyPath = Join-Path $root 'synthetic-merged-pin.key'
        $module = Get-Module DevPilot.ActivePrCanary
        & $module {
            param($PinPath, $KeyPath, $Envelope, $Key)
            Write-CanaryPrivateFile $PinPath ([Text.Encoding]::UTF8.GetBytes(
                    (ConvertTo-Json -InputObject $Envelope -Depth 8 -Compress)))
            Write-CanaryPrivateFile $KeyPath ([Text.Encoding]::UTF8.GetBytes($Key))
        } $pinPath $keyPath $script:mergedEnvelope $script:mergedKey
        $loaded = Read-CanaryPrivateMergedPin -PinPath $pinPath `
            -KeyPath $keyPath -RepositoryRoot $repo `
            -SourceSelector $script:sourceSelector
        $loaded.envelope.signature | Should -Be $script:mergedEnvelope.signature
        $loaded.envelope.pin.mergeCommit | Should -Be ('d' * 40)
        { Read-CanaryPrivateMergedPin -PinPath (
                Join-Path $repo 'samples\private-canary-source-selector.example.json') `
                -KeyPath $keyPath -RepositoryRoot $repo `
                -SourceSelector $script:sourceSelector } |
            Should -Throw '*merged-master-pin-unavailable*'
        $c.state.reads.Count | Should -Be 0
    }
    It 'rejects changed, mismatched, and previous-version private pins before any GET' {
        foreach ($failure in @('selector', 'pin', 'signature', 'key',
                'version', 'kind', 'missing-field')) {
            $c = Get-BootstrapCase
            $pin = @{} + $script:mergedEnvelope.pin
            $envelope = [ordered]@{}
            foreach ($field in $script:mergedEnvelope.Keys) {
                $envelope[$field] = $script:mergedEnvelope[$field]
            }
            $envelope.pin = $pin
            $key = $script:mergedKey
            switch ($failure) {
                selector { $envelope.selectorSignature =
                    'v1:hmac-sha256:' + ('a' * 64) }
                pin { $pin.mergeCommit = 'a' * 40 }
                signature { $envelope.signature =
                    'v1:hmac-sha256:' + ('a' * 64) }
                key { $key = 'd' * 64 }
                version { $envelope.schemaVersion = 2 }
                kind { $envelope.kind = 'private-active-candidate-pin' }
                'missing-field' {
                    $envelope.Remove('pin')
                    $envelope.extra = 'not-a-pin'
                }
            }
            { Invoke-CanaryMergedMasterPreflight `
                    -Organization $script:sourceOrg `
                    -ExpectedAccountUniqueName 'service@example.invalid' `
                    -SourceSelector $script:sourceSelector `
                    -SourceSelectorKey $script:sourceKey `
                    -MergedPinEnvelope $envelope -MergedPinKey $key `
                    -RepositoryRoot $repo -Read $c.provider -Run } |
                Should -Throw '*merged-master-pin-unavailable*' -Because $failure
            $c.state.reads.Count | Should -Be 0
            Test-Path -LiteralPath $c.root | Should -BeFalse
        }
    }
    It 'rejects a correctly re-signed but unproved merge or rule pin after GET' {
        foreach ($field in @('mergeCommit', 'sectionHash',
                'classLineHash', 'redundantLineHash',
                'classDeclarationDigest', 'redundantDeclarationDigest')) {
            $c = Get-BootstrapCase
            $pin = @{} + $script:mergedEnvelope.pin
            $pin[$field] = if ($field -eq 'mergeCommit') {
                'a' * 40
            } else { 'v1:sha256:' + ('a' * 64) }
            $envelope = [ordered]@{}
            foreach ($name in $script:mergedEnvelope.Keys) {
                $envelope[$name] = $script:mergedEnvelope[$name]
            }
            $envelope.pin = $pin
            $envelope.signature = & (Get-Module DevPilot.ActivePrCanary) {
                param($Value, $Key)
                Get-CanarySignature $Value $Key
            } $envelope $script:mergedKey
            { Invoke-CanaryMergedMasterPreflight `
                    -Organization $script:sourceOrg `
                    -ExpectedAccountUniqueName 'service@example.invalid' `
                    -SourceSelector $script:sourceSelector `
                    -SourceSelectorKey $script:sourceKey `
                    -MergedPinEnvelope $envelope -MergedPinKey $script:mergedKey `
                    -RepositoryRoot $repo -Read $c.provider -Run } |
                Should -Throw -Because $field
            $c.state.reads.Count | Should -BeGreaterThan 0
            Test-Path -LiteralPath $c.root | Should -BeFalse
            @($c.state.reads | Where-Object {
                    $_ -in @('Write', 'Post')
                }).Count | Should -Be 0
        }
    }
    It 'proves a completed PR and advanced master in memory and rechecks the account' {
        $c = Get-BootstrapCase
        $c.state.master = 'f' * 40
        $proof = Invoke-CanaryMergedMasterPreflight -Organization $script:sourceOrg `
            -ExpectedAccountUniqueName 'service@example.invalid' `
            -SourceSelector $script:sourceSelector `
            -SourceSelectorKey $script:sourceKey `
            -MergedPinEnvelope $script:mergedEnvelope `
            -MergedPinKey $script:mergedKey `
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
                $script:mergedEnvelope.pin = $originalPin
                Set-SyntheticMergedApproval
            }
        }
    }
    Describe 'Signed GET-only candidate evaluation runner' {
        It 'rejects a wrong private pin key before opening runner state or GET' {
            $c = Get-BootstrapCase
            { Invoke-PrivateCanaryEvaluation -StateRoot $c.root `
                    -RepositoryRoot $repo -SourceSelector $script:sourceSelector `
                    -SourceSelectorKey $script:sourceKey `
                    -MergedPinEnvelope $script:mergedEnvelope `
                    -MergedPinKey ('d' * 64) `
                    -ExpectedAccountUniqueName 'service@example.invalid' `
                    -Read $c.provider -Provider $c.provider -Run } |
                Should -Throw '*merged-master-pin-unavailable*'
            $c.state.reads.Count | Should -Be 0
            Test-Path -LiteralPath $c.root | Should -BeFalse
        }
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
                            $value.schemaVersion = 4
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
                $value.schemaVersion = 4
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
        $result = Invoke-PrivateCanaryBootstrap -Organization $script:sourceOrg `
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
        $dispatcher.schemaVersion | Should -Be 5
        $dispatcher.expectedAccount.Contains('uniqueName') | Should -BeFalse
        $result = Invoke-RunnerCase $c
        $result.schemaVersion | Should -Be 5
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
        $unprovenAlias = New-RunnerThread $c 1 'Exclude from code coverage.'
        $unprovenAlias.comments[0].author.uniqueName = 'other@example.invalid'
        $c.state.threads = @($unprovenAlias)
        $immutableMatch = Invoke-RunnerCase $c
        $immutableMatch.rules[1].humanCovered | Should -Be 2
        $immutableMatch.rules[1].wouldCreate | Should -Be 0
        $c.state.threads = @(New-RunnerThread $c 1 (Get-RunnerClassMarkerBody $c))
        $matchedMarker = Invoke-RunnerCase $c
        $matchedMarker.rules[1].unknown | Should -BeLessThan 2
        $matchedMarker.rules[1].humanCovered | Should -Be 0
        $matchedMarker.rules[1].wouldCreate | Should -Be 0
    }
    It 'uses only a token-bound ADO alias to disambiguate conflicting authors' {
        $c = Get-SignedIntakeCase -Code
        [void](Invoke-SignedIntakeCase $c)
        foreach ($body in @('Exclude from code coverage.',
                (Get-RunnerClassMarkerBody $c))) {
            $conflict = New-RunnerThread $c 1 $body
            $conflict.comments[0].author.uniqueName = 'other@example.invalid'
            $c.state.threads = @($conflict)
            $result = Invoke-RunnerCase $c
            $result.rules[1].unknown | Should -Be 2
            $result.rules[1].humanCovered | Should -Be 0
            $result.rules[1].wouldCreate | Should -Be 0
        }
    }
    It 'rejects alias presence and value drift within a runner invocation' {
        foreach ($mode in @('added', 'removed', 'changed')) {
            $c = Get-SignedIntakeCase -Code -MissingUniqueName:($mode -eq 'added')
            [void](Invoke-SignedIntakeCase $c)
            $original = $c.provider
            $seen = @{ count = 0 }
            $c.provider = {
                param($operation, $request)
                $answer = & $original $operation $request
                if ($operation -eq 'Identity') {
                    $seen.count++
                    if ($seen.count -eq 2) {
                        switch ($mode) {
                            added { $answer.uniqueName = 'service@example.invalid' }
                            removed { $answer.Remove('uniqueName') }
                            changed { $answer.uniqueName = 'other@example.invalid' }
                        }
                    }
                }
                return $answer
            }.GetNewClosure()
            { Invoke-RunnerCase $c } | Should -Throw '*canary-principal-drift*'
        }
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
            It 'rejects a changed merged pin before signed intake GET or state' {
                $c = Get-RegistryCase
                $root = $c.case.root + '-unapproved'
                $script:roots.Add($root)
                $c.case.state.reads.Clear()
                { Invoke-PrivateCanarySignedIntake `
                        -ProviderConfig $c.config -ApprovedSources $c.sources `
                        -StateRoot $root -RepositoryRoot $repo `
                        -CanaryPullRequestIds @(17007699) `
                        -SourceSelector $script:sourceSelector `
                        -SourceSelectorKey $script:sourceKey `
                        -MergedPinEnvelope $script:mergedEnvelope `
                        -MergedPinKey ('d' * 64) `
                        -ExpectedAccountUniqueName 'service@example.invalid' `
                        -Read $c.case.provider -Provider $c.case.provider -Run } |
                    Should -Throw '*merged-master-pin-unavailable*'
                $c.case.state.reads.Count | Should -Be 0
                Test-Path -LiteralPath $root | Should -BeFalse
            }
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
            It 'persists no CLI UPN, Graph principalName, ADO alias, or alias digest' {
                $c = Get-SignedIntakeCase -Code
                [void](Invoke-SignedIntakeCase $c)
                foreach ($root in @($c.input.case.root, $c.root)) {
                    foreach ($file in Get-ChildItem -LiteralPath $root -Recurse -File) {
                        $text = [Text.Encoding]::UTF8.GetString(
                            [IO.File]::ReadAllBytes($file.FullName))
                        $text | Should -Not -Match `
                            'service@example.invalid|principalName|uniqueName|expectedCliUpn'
                    }
                }
                $config = Get-Content -LiteralPath (
                    Join-Path $c.root 'canary-dispatcher.json') -Raw |
                    ConvertFrom-Json -AsHashtable
                $config.schemaVersion | Should -Be 5
                $config.principalProof |
                    Should -Be 'aad-graph-storage-key-alias-free-v2'
                $config.expectedAccount.Count | Should -Be 2
                $config.expectedAccount.Keys | Should -Contain 'id'
                $config.expectedAccount.Keys | Should -Contain 'descriptor'
                $intake = Get-Content -LiteralPath (
                    Join-Path $c.root 'canary-intake.json') -Raw |
                    ConvertFrom-Json -AsHashtable
                $intake.schemaVersion | Should -Be 3
                $intake.limits.maxFileBytes | Should -Be 262144
                (Invoke-RunnerCase $c).providerWrites | Should -Be 0
            }
            It 'refuses split inventory, stale heads, fake graph and forged receipt before signing' {
                foreach ($failure in @('identity-upn', 'identity-alias',
                        'alias-added', 'alias-removed',
                        'split-page', 'stale-head', 'fake-graph',
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
            It 'preserves typed, selector-free inventory and transport diagnostics without state' {
                foreach ($mode in @('split-page', 'inaccessible-page',
                        'stale-head', 'throttle-changes')) {
                    $c = Get-SignedIntakeCase -CoverageOnly -Code
                    $c.state.wrong = $mode
                    $diagnostic = [ref]$null
                    { Invoke-SignedIntakeCase $c $diagnostic } |
                        Should -Throw -Because $mode
                    $d = $diagnostic.Value
                    $d.state | Should -Be 'blocked'
                    $d.signed | Should -BeFalse
                    $d.privateIntakePersisted | Should -BeFalse
                    $d.selected.Count | Should -Be 2
                    $d.provider.attemptedCalls | Should -BeGreaterThan 0
                    $d.provider.completedGets | Should -BeNullOrEmpty
                    $d.provider.attemptedGets | Should -BeNullOrEmpty
                    if ($mode -eq 'split-page') {
                        $d.failureCode | Should -Be 'canary-inventory-unknown'
                        $d.reasonCodes | Should -Contain 'missing-page'
                        $d.failedChecks | Should -Contain 'enumeration-gap'
                        $d.selected[0].inventoryEligible | Should -BeNullOrEmpty
                    } elseif ($mode -eq 'inaccessible-page') {
                        $d.reasonCodes | Should -Contain 'page-inaccessible'
                        $d.failureCode | Should -Be 'canary-inventory-unknown'
                    } elseif ($mode -eq 'stale-head') {
                        $d.failureCode | Should -Be 'canary-head-or-evidence-unknown'
                        $d.driftState | Should -Be 'detected'
                        $d.selected[0].inventoryEligible | Should -BeTrue
                    } else {
                        $d.failureCode | Should -Be 'read-throttled'
                        $d.throttleState | Should -Be 'detected'
                        $d.provider.attemptedCalls |
                            Should -BeGreaterThan $d.provider.completedCalls
                    }
                    ($d | ConvertTo-Json -Depth 10) |
                        Should -Not -Match 'private route|ExampleSource|ExampleRepo|service@example.invalid'
                    Test-Path -LiteralPath $c.root | Should -BeFalse
                }
            }
            It 'preserves every selected intake safe code through the signed-intake failure diagnostic' {
                $cases = @(
                    @{ code = 'invalid-head'; method = 'Head' },
                    @{ code = 'head-inconsistent'; method = 'Head' },
                    @{ code = 'head-drift'; method = 'Head' },
                    @{ code = 'file-budget'; method = 'Changes' },
                    @{ code = 'line-budget'; method = 'Changes' },
                    @{ code = 'line-count-unavailable'; method = 'Changes' },
                    @{ code = 'account-mismatch'; method = 'Changes' },
                    @{ code = 'change-list-truncated'; method = 'Changes' },
                    @{ code = 'change-page-budget'; method = 'Changes' },
                    @{ code = 'invalid-discussions'; method = 'Discussions' },
                    @{ code = 'mutable-discussions'; method = 'Discussions' },
                    @{ code = 'comment-budget'; method = 'Discussions' },
                    @{ code = 'invalid-evaluator'; method = 'Changes' },
                    @{ code = 'invalid-observation'; method = 'Changes' },
                    @{ code = 'read-budget'; method = 'Changes' },
                    @{ code = 'time-budget'; method = 'Changes' },
                    @{ code = 'invalid-change'; method = 'Changes' },
                    @{ code = 'invalid-item'; method = 'Changes' },
                    @{ code = 'byte-budget'; method = 'Changes' },
                    @{ code = 'diff-budget'; method = 'Changes' },
                    @{ code = 'unsupported-change'; method = 'Changes' },
                    @{ code = 'project-identity-unknown'; method = 'Changes' }
                )
                $intakeSource = Get-Content -LiteralPath (
                    Join-Path $repo 'src\DevPilot.ActivePrIntake\DevPilot.ActivePrIntake.psm1') -Raw
                $selectedCatch = [regex]::Match($intakeSource,
                    '(?s)\$reason -cnotin @\((?<codes>.*?)\)\) \{\s*\$reason = ''provider-inaccessible''')
                $selectedCatch.Success | Should -BeTrue
                $upstreamCodes = @([regex]::Matches(
                        $selectedCatch.Groups['codes'].Value,
                        "'(?<code>[a-z][a-z0-9-]*)'") |
                    ForEach-Object { $_.Groups['code'].Value } |
                    Sort-Object -Unique)
                @(Compare-Object $upstreamCodes @($cases.code | Sort-Object -Unique)) |
                    Should -BeNullOrEmpty
                foreach ($test in $cases) {
                    $c = Get-SignedIntakeCase -CoverageOnly -Code
                    $inner = $c.provider
                    $method = $test.method
                    $code = $test.code
                    $c.provider = {
                        param($operation, $request)
                        if ($operation -ceq $method -and
                            $request.pullRequestId -eq 17007699) {
                            throw $code
                        }
                        & $inner $operation $request
                    }.GetNewClosure()
                    $diagnostic = [ref]$null
                    { Invoke-SignedIntakeCase $c $diagnostic } |
                        Should -Throw -Because $code
                    $d = $diagnostic.Value
                    $d.failureCode | Should -Be 'canary-head-or-evidence-unknown' -Because $code
                    $d.selected[0].reason | Should -BeExactly $code
                    $d.selected[0].method | Should -BeExactly $method
                    $d.selected[0].stage | Should -Be 'provider-call'
                    $d.selected[0].headProof | Should -Be 'unknown'
                    $d.selected[0].inventoryEligible | Should -BeTrue
                    $d.selected[1].headProof | Should -Be 'pending'
                    $d.selected[1].method | Should -Be 'unknown'
                    $d.selected[1].stage | Should -Be 'unknown'
                    $d.provider.attemptedCalls |
                        Should -Be ($d.provider.completedCalls + 1)
                    $d.provider.attemptedGets | Should -BeNullOrEmpty
                    $d.provider.completedGets | Should -BeNullOrEmpty
                    $d.privateIntakePersisted | Should -BeFalse
                    $d.signed | Should -BeFalse
                    $d.writerEligible | Should -BeFalse
                    $d.providerWrites | Should -Be 0
                    Test-Path -LiteralPath $c.root | Should -BeFalse
                }
            }
            It 'redacts unapproved provider errors and does not invent validation method or transport counts' {
                $c = Get-SignedIntakeCase -CoverageOnly -Code
                $inner = $c.provider
                $c.provider = {
                    param($operation, $request)
                    if ($operation -ceq 'Changes' -and
                        $request.pullRequestId -eq 17007699) {
                        throw 'private route /secret/account@example.invalid and key'
                    }
                    & $inner $operation $request
                }.GetNewClosure()
                $diagnostic = [ref]$null
                { Invoke-SignedIntakeCase $c $diagnostic } | Should -Throw
                $d = $diagnostic.Value
                $d.selected[0].reason | Should -Be 'provider-inaccessible'
                $d.selected[0].method | Should -Be 'Changes'
                $d.selected[0].stage | Should -Be 'provider-call'
                $d.selected[0].inventoryEligible | Should -BeTrue
                $d.privateIntakePersisted | Should -BeFalse
                $d.provider.attemptedGets | Should -BeNullOrEmpty
                $d.provider.completedGets | Should -BeNullOrEmpty
                ($d | ConvertTo-Json -Depth 12) |
                    Should -Not -Match 'private route|/secret|account@example.invalid|and key'
                Test-Path -LiteralPath $c.root | Should -BeFalse

                $validated = Get-SignedIntakeCase -CoverageOnly -Code
                $validProvider = $validated.provider
                $validated.provider = {
                    param($operation, $request)
                    $answer = & $validProvider $operation $request
                    if ($operation -ceq 'Changes' -and
                        $request.pullRequestId -eq 17007699) {
                        $answer.files[0].spans[0].startLine = 2
                    }
                    return $answer
                }.GetNewClosure()
                $validationDiagnostic = [ref]$null
                { Invoke-SignedIntakeCase $validated $validationDiagnostic } |
                    Should -Throw
                $v = $validationDiagnostic.Value
                $v.selected[0].reason | Should -Be 'invalid-change'
                $v.selected[0].method | Should -Be 'unknown'
                $v.selected[0].stage | Should -Be 'unknown'
                $v.provider.attemptedCalls | Should -Be $v.provider.completedCalls
                $v.privateIntakePersisted | Should -BeFalse
                Test-Path -LiteralPath $validated.root | Should -BeFalse
            }
            It 'keeps each selected failing provider method separate' {
                $c = Get-SignedIntakeCase -CoverageOnly -Code
                $inner = $c.provider
                $c.provider = {
                    param($operation, $request)
                    if ($operation -ceq 'Changes' -and
                        $request.pullRequestId -eq 17007699) {
                        throw 'invalid-change'
                    }
                    if ($operation -ceq 'Discussions' -and
                        $request.pullRequestId -eq 17109075) {
                        throw 'invalid-discussions'
                    }
                    & $inner $operation $request
                }.GetNewClosure()
                $diagnostic = [ref]$null
                { Invoke-SignedIntakeCase $c $diagnostic } | Should -Throw
                $d = $diagnostic.Value
                $d.selected[0].reason | Should -Be 'invalid-change'
                $d.selected[0].method | Should -Be 'Changes'
                $d.selected[1].reason | Should -Be 'invalid-discussions'
                $d.selected[1].method | Should -Be 'Discussions'
                @($d.selected | Where-Object stage -NE 'provider-call').Count |
                    Should -Be 0
                $d.provider.attemptedCalls |
                    Should -Be ($d.provider.completedCalls + 2)
                $d.privateIntakePersisted | Should -BeFalse
                Test-Path -LiteralPath $c.root | Should -BeFalse
            }
            It 'reports only bound observed byte-budget counts without inventing full file size' {
                $cohort = @{
                    inventory = @{ state = 'complete'; active = 2
                        nonDraft = 2; draft = 0; eligible = 2
                        excludedOtherTargets = 0 }
                    populationKnown = $true
                    gapCounts = @{ enumerationUnknown = 0
                        duplicateEntries = 0; drift = 0 }
                    reasonCodes = @()
                    heads = @(
                        @{ pullRequestId = 101; status = 'unknown'
                            targetRef = 'refs/heads/master'
                            reason = 'byte-budget' },
                        @{ pullRequestId = 202; status = 'pending'
                            targetRef = 'refs/heads/master'
                            reason = 'rules-incomplete' })
                    pages = @{ first = 1; second = 1 }
                    readCount = 9
                }
                $d = & (Get-Module DevPilot.ActivePrCanary) {
                    param($Cohort)
                    New-CanaryIntakeFailureDiagnostic $Cohort `
                        @(101, 202) `
                        @{ attemptedGets = 5; completedGets = 4
                            responseHeadersCompleted = 5; throttleEvents = 0
                            lastHttpStatus = $null } `
                        @{ attempted = 2; completed = 1
                            failedMethods = @{ 101 = 'Changes' }
                            byteBudgets = @{ 101 = @{
                                    effectiveCapBytes = 262144
                                    bytesRead = 270336; declaredBytes = $null
                                    phase = 'body-read' } } } $null $null
                } $cohort
                $d.selected[0].reason | Should -Be 'byte-budget'
                $d.selected[0].limitKind | Should -Be 'raw-item-byte-cap'
                $d.selected[0].limitCount | Should -Be 262144
                $d.selected[0].bytesRead | Should -Be 270336
                $d.selected[0].declaredBytes | Should -BeNullOrEmpty
                $d.selected[0].bodyPhase | Should -Be 'body-read'
                $d.selected[0].endpointKind | Should -Be 'items'
                $d.selected[1].limitKind | Should -BeNullOrEmpty
                $d.selected[1].bytesRead | Should -BeNullOrEmpty
                $d.provider.completedGets | Should -Be 4
                $d.provider.responseHeadersCompleted | Should -Be 5
                $d.throttleState | Should -Be 'unknown'
                $d.privateIntakePersisted | Should -BeNullOrEmpty
            }
            It 'distinguishes inventory duplicates and cardinality without assuming eligibility' {
                $cohort = @{
                    inventory = @{ state = 'complete'; active = 4
                        nonDraft = 3; draft = 1; eligible = 2
                        excludedOtherTargets = 1 }
                    populationKnown = $true
                    gapCounts = @{ enumerationUnknown = 0
                        duplicateEntries = 1; drift = 0 }
                    reasonCodes = @('private detail')
                    heads = @(@{ pullRequestId = 17007699; status = 'pending'
                            targetRef = 'refs/heads/master'; reason = 'rules-incomplete' })
                    pages = @{ first = 2; second = 2 }
                    readCount = 8
                }
                $d = & (Get-Module DevPilot.ActivePrCanary) {
                    param($Cohort)
                    New-CanaryIntakeFailureDiagnostic $Cohort `
                        @(17007699, 17109075) $null `
                        @{ attempted = 4; completed = 3 } $null $null
                } $cohort
                $d.failedChecks | Should -Contain 'duplicate-entries'
                $d.failedChecks | Should -Contain 'non-draft-cardinality'
                $d.selected[0].inventoryEligible | Should -BeNullOrEmpty
                $d.selected[1].inventoryEligible | Should -BeNullOrEmpty
                $d.reasonCodes | Should -BeNullOrEmpty
                $d.inventory.intakeReportedReads | Should -Be 8
                ($d | ConvertTo-Json -Depth 8) | Should -Not -Match 'private detail'
            }
            It 'only reports selected eligibility after every inventory proof succeeds' {
                $baseline = @{
                    inventory = @{ state = 'complete'; active = 3
                        nonDraft = 2; draft = 1; eligible = 1
                        excludedOtherTargets = 1 }
                    populationKnown = $true
                    gapCounts = @{ enumerationUnknown = 0
                        duplicateEntries = 0; drift = 0 }
                    reasonCodes = @()
                    heads = @(
                        @{ pullRequestId = 17007699; status = 'pending'
                            targetRef = 'refs/heads/master'
                            reason = 'rules-incomplete' },
                        @{ pullRequestId = 17109075; status = 'pending'
                            targetRef = 'refs/heads/release'
                            reason = 'rules-incomplete' })
                    pages = @{ first = 1; second = 1 }
                    readCount = 8
                }
                foreach ($mode in @('complete', 'inventory', 'population',
                        'enumeration', 'duplicate', 'non-draft', 'active',
                        'eligible')) {
                    $cohort = ConvertFrom-Json -AsHashtable (
                        ConvertTo-Json $baseline -Depth 10)
                    switch ($mode) {
                        inventory { $cohort.inventory.state = 'unknown' }
                        population { $cohort.populationKnown = $false }
                        enumeration { $cohort.gapCounts.enumerationUnknown = 1 }
                        duplicate { $cohort.gapCounts.duplicateEntries = 1 }
                        non-draft { $cohort.inventory.nonDraft = 3 }
                        active { $cohort.inventory.active = 4 }
                        eligible { $cohort.inventory.eligible = 2 }
                    }
                    $d = & (Get-Module DevPilot.ActivePrCanary) {
                        param($Cohort)
                        New-CanaryIntakeFailureDiagnostic $Cohort `
                            @(17007699, 17109075) $null `
                            @{ attempted = 4; completed = 4 } $null $null
                    } $cohort
                    if ($mode -eq 'complete') {
                        $d.selected[0].inventoryEligible | Should -BeTrue
                        $d.selected[1].inventoryEligible | Should -BeFalse
                    } else {
                        $d.selected[0].inventoryEligible | Should -BeNullOrEmpty
                        $d.selected[1].inventoryEligible | Should -BeNullOrEmpty
                        $d.failedChecks.Count | Should -BeGreaterThan 0
                    }
                }
                $cohort = ConvertFrom-Json -AsHashtable (
                    ConvertTo-Json $baseline -Depth 10)
                $cohort.heads[0].status = 'unknown'
                $cohort.heads[0].reason = 'head-inconsistent'
                $d = & (Get-Module DevPilot.ActivePrCanary) {
                    param($Cohort)
                    New-CanaryIntakeFailureDiagnostic $Cohort `
                        @(17007699, 17109075) $null `
                        @{ attempted = 4; completed = 3 } $null $null
                } $cohort
                $d.selected[0].inventoryEligible | Should -BeTrue
                $d.selected[0].headProof | Should -Be 'unknown'
                $d.selected[0].reason | Should -Be 'head-inconsistent'
                $d.failedChecks | Should -Contain 'selected-head-or-evidence-unknown'
                $cohort.heads[0].reason = 'diff-budget'
                $d = & (Get-Module DevPilot.ActivePrCanary) {
                    param($Cohort)
                    New-CanaryIntakeFailureDiagnostic $Cohort `
                        @(17007699, 17109075) $null `
                        @{ attempted = 4; completed = 3 } $null $null
                } $cohort
                $d.selected[0].reason | Should -Be 'diff-budget'
                $d.selected[0].limitKind | Should -Be 'maxDiffCells'
                $d.selected[0].limitCount | Should -BeNullOrEmpty
                $cohort.heads[0].reason = 'private-route-must-not-appear'
                $d = & (Get-Module DevPilot.ActivePrCanary) {
                    param($Cohort)
                    New-CanaryIntakeFailureDiagnostic $Cohort `
                        @(17007699, 17109075) $null `
                        @{ attempted = 4; completed = 3 } $null $null
                } $cohort
                $d.selected[0].reason | Should -Be 'unavailable'
            }
            It 'reports source drift even when the inventory itself is complete' {
                $c = Get-SignedIntakeCase -Code -CoverageOnly
                $provider = $c.provider
                $config = $c.input.config
                $c.provider = {
                    param($Operation, $Request)
                    if ($Operation -ceq 'ListPage') {
                        $config.syntheticNote = 'changed-after-source-proof'
                    }
                    & $provider $Operation $Request
                }.GetNewClosure()
                $diagnostic = [ref]$null
                { Invoke-SignedIntakeCase $c $diagnostic } |
                    Should -Throw '*canary-source-drift*'
                $diagnostic.Value.failureCode | Should -Be 'canary-source-drift'
                $diagnostic.Value.driftState | Should -Be 'detected'
                $diagnostic.Value.privateIntakePersisted | Should -BeFalse
            }
            It 'keeps actual failed GET attempts distinct from completed source and provider GETs' {
                $provider = [ordered]@{ attemptedGets = 4; completedGets = 3
                    throttleEvents = 1; lastHttpStatus = 429 }
                $source = [ordered]@{ attemptedGets = 24; completedGets = 24
                    throttleEvents = 0; lastHttpStatus = $null }
                $d = & (Get-Module DevPilot.ActivePrCanary) {
                    param($Provider, $Source)
                    New-CanaryIntakeFailureDiagnostic $null `
                        @(17007699, 17109075) $Provider `
                        @{ attempted = 2; completed = 1 } 24 $Source
                } $provider $source
                $d.provider.totalAttemptedGets | Should -Be 28
                $d.provider.totalCompletedGets | Should -Be 27
                $d.provider.throttleEvents | Should -Be 1
                $d.provider.lastHttpStatus | Should -Be 429
                $d.throttleState | Should -Be 'detected'
                $d.selected[0].inventoryEligible | Should -BeNullOrEmpty
                $d.privateIntakePersisted | Should -BeNullOrEmpty
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
            It 'reports a removed private intake root after a post-proof write failure' {
                $c = Get-SignedIntakeCase -Code -CoverageOnly
                Mock Write-CanaryPrivateFile -ModuleName DevPilot.ActivePrCanary {
                    throw 'signed-file-failed'
                } -ParameterFilter { $Path -like '*canary-dispatcher.json' }
                $diagnostic = [ref]$null
                { Invoke-SignedIntakeCase $c $diagnostic } |
                    Should -Throw '*signed-file-failed*'
                $diagnostic.Value.privateIntakePersisted | Should -BeFalse
                $diagnostic.Value.failureCode | Should -Be 'canary-preflight-incomplete'
                Test-Path -LiteralPath $c.root | Should -BeFalse
            }
            It 'preserves cleanup failure and reports the retained private root' {
                $c = Get-SignedIntakeCase -Code -CoverageOnly
                Mock Write-CanaryPrivateFile -ModuleName DevPilot.ActivePrCanary {
                    throw 'signed-file-failed'
                } -ParameterFilter { $Path -like '*canary-dispatcher.json' }
                Mock Remove-AgentContainedDirectory -ModuleName DevPilot.ActivePrCanary {
                    throw 'private filesystem detail'
                }
                $diagnostic = [ref]$null
                { Invoke-SignedIntakeCase $c $diagnostic } |
                    Should -Throw '*canary-private-state-cleanup-failed*'
                $diagnostic.Value.failureCode |
                    Should -Be 'canary-private-state-cleanup-failed'
                $diagnostic.Value.privateIntakePersisted | Should -BeTrue
                Test-Path -LiteralPath $c.root | Should -BeTrue
                ($diagnostic.Value | ConvertTo-Json -Depth 10) |
                    Should -Not -Match 'private filesystem detail'
            }
            It 'preserves a typed cleanup failure in CLI-facing output' {
                . (Join-Path $repo 'tools\PrivateCanarySignedIntakeFailure.ps1')
                $diagnostic = [ordered]@{
                    failureCode = 'canary-private-state-cleanup-failed'
                    privateIntakePersisted = $true; state = 'blocked'
                }
                $output = [Collections.Generic.List[string]]::new()
                $errorText = ''
                try {
                    Write-PrivateCanarySignedIntakeFailure $diagnostic |
                        ForEach-Object { $output.Add([string]$_) }
                }
                catch { $errorText = $_.Exception.Message }
                $errorText | Should -Be 'canary-private-state-cleanup-failed'
                ($output.ToArray() -join '') |
                    Should -Match '"privateIntakePersisted":true'
                ($output.ToArray() -join '') |
                    Should -Match '"failureCode":"canary-private-state-cleanup-failed"'
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
            $result.providerReads | Should -Be 29
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
            foreach ($failure in @('schema', 'previous-v3', 'previous-v5',
                    'identity-digest', 'missing', 'source-organization',
                    'source-project', 'source-repository',
                    'owner', 'owner-length',
                    'named-section', 'named-blob', 'class', 'redundant',
                    'class-master', 'named-policy', 'named-digest', 'repository',
                    'project')) {
                $inputCase = Get-RegistryCase
                switch ($failure) {
                    schema { $inputCase.sources.schemaVersion = 2 }
                    'previous-v3' {
                        $inputCase.sources.schemaVersion = 5
                        $inputCase.sources.kind = 'private-read-only-canary-sources'
                        $inputCase.sources.sourceAuthority =
                            'unmerged-reviewed-pr-is-candidate-only'
                    }
                    'previous-v5' { $inputCase.sources.schemaVersion = 5 }
                    'source-organization' {
                        $inputCase.sources.rules['bpm-test-ownership@1'].organization =
                            'wrong-org'
                    }
                    'source-project' {
                        $inputCase.sources.rules['bpm-test-class-coverage@2'].projectName =
                            'WrongSource'
                    }
                    'source-repository' {
                        $inputCase.sources.rules['bpm-redundant-method-coverage@2'].repositoryName =
                            'WrongRepo'
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
        $config.expectedAccount.Count | Should -Be 2
        $config.expectedAccount.Contains('principalName') | Should -BeFalse
        $config.Contains('operator') | Should -BeFalse
        $manifest.schemaVersion | Should -Be 6
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
            $request = @{ projectName = 'ExampleSource'
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
                $handler.Paths[2] | Should -Match '/ExampleSource/_apis/git/repositories/44444444-4444-4444-4444-444444444444/items\?'
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
        foreach ($mode in @('budget', 'budget-low', 'budget-zero',
                '429', '503', 'retry-after', 'delay')) {
            $handler = [CanarySyntheticHandler]::new()
            if ($mode -in @('429', '503')) {
                $handler.Status = [Net.HttpStatusCode][int]$mode
            }
            if ($mode -eq 'retry-after') { $handler.ThrottleHint = $true }
            if ($mode -eq 'delay') { $handler.DelayHint = $true }
            if ($mode -eq 'budget') { $handler.BudgetRemaining = '8' }
            if ($mode -eq 'budget-low') { $handler.BudgetRemaining = '1' }
            if ($mode -eq 'budget-zero') { $handler.BudgetRemaining = '0' }
            $client = [Net.Http.HttpClient]::new($handler)
            $module = Get-Module DevPilot.ActivePrCanary
            try {
                $read = {
                    & $module {
                        param($Client)
                        Invoke-CanaryAadGet $Client 'synthetic-bearer' `
                            'example-org' 'Project' @{ projectName = 'ExampleSource' } `
                            ([DateTime]::UtcNow.AddSeconds(5))
                    } $client
                }
                if ($mode -like 'budget*') {
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
    It 'binds alias-free intake v3 to an ephemeral UPN and immutable Graph proof' {
        $config = Get-Content (Join-Path $repo 'samples\active-pr-intake.config.json') `
            -Raw | ConvertFrom-Json -AsHashtable
        $config.schemaVersion = 3
        $config.principalProof = 'aad-graph-storage-key-alias-free-v2'
        $config.expectedAccount = @{
            id = '33333333-3333-3333-3333-333333333333'
            descriptor = 'aad.synthetic' }
        $config.enabled = $true
        foreach ($mode in @('match', 'upn', 'storage', 'wrong-cli')) {
            $handler = [CanaryBoundGetHandler]::new()
            $handler.DriftGraphUpn = $mode -eq 'upn'
            $handler.DriftStorageKey = $mode -eq 'storage'
            $client = [Net.Http.HttpClient]::new($handler)
            try {
                $expected = if ($mode -eq 'wrong-cli') {
                    'other@example.invalid'
                } else { 'service@example.invalid' }
                $provider = New-ActivePrAzureDevOpsProvider -Config $config `
                    -BoundClient $client -BearerToken ('b' * 100) `
                    -ExpectedPrincipalName $expected -VerifyReadPrincipal
                if ($mode -eq 'match') {
                    $identity = & $provider Identity @{ timeoutMilliseconds = 5000 }
                    $identity.id | Should -Be $config.expectedAccount.id
                    $identity.principalName | Should -Be $expected
                    $handler.Tokens.Count | Should -Be 3
                } else {
                    { & $provider Identity @{ timeoutMilliseconds = 5000 } } |
                        Should -Throw '*account-mismatch*'
                }
                $handler.Paths.Count | Should -Be $(if ($mode -eq 'wrong-cli') {
                        1
                    } else { 3 })
                @($handler.Tokens | Where-Object { $_ -cne ('b' * 100) }).Count |
                    Should -Be 0
            }
            finally { $client.Dispose() }
        }
        ($config | ConvertTo-Json -Depth 10) |
            Should -Not -Match 'service@example.invalid|principalName|uniqueName'
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
                $transport = [ordered]@{
                    attemptedGets = 0; completedGets = 0
                    throttleEvents = 0; lastHttpStatus = $null
                }
                $provider = New-ActivePrAzureDevOpsProvider -Config $config `
                    -BearerToken ('b' * 100) -BoundClient $client -VerifyReadPrincipal `
                    -TransportTelemetry $transport
                if ($mode -eq 'throttle') {
                    [void](& $provider Identity @{ timeoutMilliseconds = 5000 })
                    { & $provider ListPage @{ skip = 0; top = 50
                            timeoutMilliseconds = 5000 } } |
                        Should -Throw '*read-throttled*'
                    $handler.Paths.Count | Should -Be 4
                    $transport.attemptedGets | Should -Be 4
                    $transport.completedGets | Should -Be 3
                    $transport.throttleEvents | Should -Be 1
                    $transport.lastHttpStatus | Should -Be 429
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
    It 'separately binds current target ref and historical iteration target in coverage mode' {
        $config = Get-Content (Join-Path $repo 'samples\active-pr-intake.config.json') `
            -Raw | ConvertFrom-Json -AsHashtable
        $config.schemaVersion = 3
        $config.principalProof = 'aad-graph-storage-key-alias-free-v2'
        $config.expectedAccount = @{ id = '33333333-3333-3333-3333-333333333333'
            descriptor = 'aad.synthetic' }
        $config.enabled = $true
        $config.pagination = @{ mode = 'created-time-keyset' }
        $config.headProof = 'iteration-source-current-target-v1'
        foreach ($mode in @('normal-advanced', 'historical-source',
                'historical-target', 'wrong-source', 'wrong-repository',
                'malformed-target', 'retarget')) {
            $handler = [CanaryBoundGetHandler]::new()
            $handler.AdvancedTargetRef = $true
            $handler.HistoricSourceCommit = $mode -eq 'historical-source'
            $handler.HistoricTargetCommit = $mode -eq 'historical-target'
            $handler.DriftRef = $mode -eq 'wrong-source'
            $handler.WrongRepository = $mode -eq 'wrong-repository'
            $handler.MalformedTargetRef = $mode -eq 'malformed-target'
            $handler.Retarget = $mode -eq 'retarget'
            $client = [Net.Http.HttpClient]::new($handler)
            try {
                $telemetry = [ordered]@{ attemptedGets = 0; completedGets = 0
                    throttleEvents = 0; lastHttpStatus = $null }
                $provider = New-ActivePrAzureDevOpsProvider -Config $config `
                    -BearerToken ('b' * 100) -BoundClient $client `
                    -VerifyReadPrincipal -ExpectedPrincipalName 'service@example.invalid' `
                    -TransportTelemetry $telemetry
                [void](& $provider Identity @{ timeoutMilliseconds = 5000 })
                if ($mode -in @('wrong-source', 'malformed-target', 'retarget')) {
                    { & $provider Head @{ pullRequestId = 7
                            remainingReads = 10; timeoutMilliseconds = 5000 } } |
                        Should -Throw '*head-inconsistent*'
                } else {
                    $head = & $provider Head @{ pullRequestId = 7
                        remainingReads = 10; timeoutMilliseconds = 5000 }
                    if ($mode -eq 'wrong-repository') {
                        { & (Get-Module DevPilot.ActivePrIntake) {
                                param($Head, $Config)
                                Assert-IntakeHead $Head 7 $Config
                            } $head $config } | Should -Throw '*invalid-head*'
                    } else {
                        $verified = & (Get-Module DevPilot.ActivePrIntake) {
                            param($Head, $Config)
                            Assert-IntakeHead $Head 7 $Config
                        } $head $config
                        $verified.sourceCommit | Should -Be ('a' * 40)
                        $verified.targetCommit | Should -Be ('b' * 40)
                        $verified.commonCommit | Should -Be ('c' * 40)
                        $verified.currentTargetCommit | Should -Be ('e' * 40)
                        $handler.Paths.Count | Should -Be 7
                        $telemetry.completedGets | Should -Be 7
                    }
                }
            }
            finally { $client.Dispose() }
        }
    }
    It 'counts actual bound GET attempts and surfaces only safe throttle or HTTP status' {
        $config = Get-Content (Join-Path $repo 'samples\active-pr-intake.config.json') `
            -Raw | ConvertFrom-Json -AsHashtable
        $config.schemaVersion = 2
        $config.principalProof = 'aad-graph-storage-key-v1'
        $config.expectedAccount.descriptor = 'aad.synthetic'
        $config.expectedAccount.principalName = 'service@example.invalid'
        $config.enabled = $true
        foreach ($mode in @('rate-hint', 'rate-delay', '429', '503',
                'budget-low', 'budget-zero', 'http-error')) {
            $handler = [CanaryBoundGetHandler]::new()
            $handler.ThrottleHintInventory = $mode -eq 'rate-hint'
            $handler.DelayHintInventory = $mode -eq 'rate-delay'
            $handler.ThrottleInventory = $mode -eq '429'
            $handler.ServiceUnavailableInventory = $mode -eq '503'
            if ($mode -eq 'budget-low') { $handler.InventoryRemaining = '1' }
            if ($mode -eq 'budget-zero') { $handler.InventoryRemaining = '0' }
            $handler.MissingInventory = $mode -eq 'http-error'
            $client = [Net.Http.HttpClient]::new($handler)
            try {
                $transport = [ordered]@{
                    attemptedGets = 0; completedGets = 0
                    throttleEvents = 0; lastHttpStatus = $null
                }
                $provider = New-ActivePrAzureDevOpsProvider -Config $config `
                    -BearerToken ('b' * 100) -BoundClient $client `
                    -VerifyReadPrincipal -TransportTelemetry $transport
                [void](& $provider Identity @{ timeoutMilliseconds = 5000 })
                $read = { & $provider ListPage @{ skip = 0; top = 50
                        timeoutMilliseconds = 5000 } }
                if ($mode -like 'budget*') {
                    (& $read).count | Should -Be 0
                } else {
                    { & $read } | Should -Throw $(if ($mode -ne 'http-error') {
                            '*read-throttled*'
                        } else { '*read-inaccessible*' })
                }
                $transport.attemptedGets | Should -Be 4
                $transport.completedGets | Should -Be $(if (
                        $mode -like 'budget*') { 4 } else { 3 })
                $handler.Paths.Count | Should -Be 4
                $transport.throttleEvents | Should -Be $(if (
                        $mode -ne 'http-error' -and
                        $mode -notlike 'budget*') { 1 } else { 0 })
                $transport.lastHttpStatus | Should -Be $(if (
                        $mode -in @('rate-hint', 'rate-delay')) { 200 } elseif (
                        $mode -eq 'http-error') { 404 } elseif (
                        $mode -like 'budget*') { $null } else { [int]$mode })
                ($transport | ConvertTo-Json) |
                    Should -Not -Match 'example-org|service@example.invalid|aad.synthetic'
            }
            finally { $client.Dispose() }
        }
    }
    It 'preserves source registry GET attempts when a same-bearer Graph proof throttles' {
        $c = Get-RegistryCase -CoverageOnly
        $handler = [CanaryBoundGetHandler]::new()
        $handler.ThrottleGraphStorage = $true
        $client = [Net.Http.HttpClient]::new($handler)
        try {
            $telemetry = [ordered]@{
                attemptedGets = 0; completedGets = 0
                throttleEvents = 0; lastHttpStatus = $null
            }
            { Invoke-PrivateCanaryRuleRegistry -ProviderConfig $c.config `
                    -ApprovedSources $c.sources -RepositoryRoot $repo `
                    -SourceSelector $script:sourceSelector `
                    -SourceSelectorKey $script:sourceKey `
                    -MergedPinEnvelope $script:mergedEnvelope `
                    -MergedPinKey $script:mergedKey `
                    -ExpectedAccountUniqueName 'service@example.invalid' `
                    -BearerSession @{ client = $client; token = ('b' * 100) } `
                    -ReadTelemetry $telemetry -Mode CoverageOnly -Run } |
                Should -Throw '*bootstrap-read-throttled:GraphStorageKey*'
            $telemetry.attemptedGets | Should -Be 3
            $telemetry.completedGets | Should -Be 2
            $telemetry.throttleEvents | Should -Be 1
            $telemetry.lastHttpStatus | Should -Be 429
            $handler.Paths.Count | Should -Be 3
            ($telemetry | ConvertTo-Json) |
                Should -Not -Match 'example-org|service@example.invalid'
        }
        finally { $client.Dispose() }
    }
}

Describe 'Coverage-only signed read-only canary' {
    It 'keeps coverage entry points disabled without ADO or state' {
        $c = Get-BootstrapCase
        (Invoke-PrivateCanaryBootstrap -Organization $script:sourceOrg `
            -ProjectName 'ExampleProject' -RepositoryName 'ExampleRepo' `
            -ExpectedAccountUniqueName 'service@example.invalid' `
            -StateRoot $c.root -RepositoryRoot $repo `
            -Mode CoverageOnly).state | Should -Be 'disabled'
        (New-VerifiedCanaryRuleRegistry -ProviderConfig @{} `
            -ApprovedSources @{} -RepositoryRoot $repo `
            -Mode CoverageOnly).state | Should -Be 'disabled'
        (Invoke-PrivateCanarySignedIntake -ProviderConfig @{} `
            -ApprovedSources @{} -StateRoot $c.root `
            -RepositoryRoot $repo -CanaryPullRequestIds @(7) `
            -Mode CoverageOnly).state | Should -Be 'disabled'
        (Invoke-PrivateCanaryEvaluation -StateRoot $c.root `
            -RepositoryRoot $repo -Mode CoverageOnly).state | Should -Be 'disabled'
        $c.state.reads.Count | Should -Be 0
        Test-Path $c.root | Should -BeFalse
    }
    It 'requires the private source pin before GET or private root' {
        $c = Get-BootstrapCase
        { Invoke-PrivateCanaryBootstrap -Organization $script:sourceOrg `
                -ProjectName 'ExampleProject' -RepositoryName 'ExampleRepo' `
                -ExpectedAccountUniqueName 'service@example.invalid' `
                -StateRoot $c.root -RepositoryRoot $repo `
                -SourceSelector $script:sourceSelector `
                -SourceSelectorKey $script:sourceKey `
                -MergedPinEnvelope $null -MergedPinKey $script:mergedKey `
                -Read $c.provider -Mode CoverageOnly -Run } |
            Should -Throw '*merged-master-pin-unavailable*'
        $c.state.reads.Count | Should -Be 0
        Test-Path $c.root | Should -BeFalse
    }
    It 'prepares exactly two independently hashed receipts without Owner approval' {
        $c = Get-BootstrapCase
        $module = Get-Module DevPilot.ActivePrCanary
        & $module { $script:OwnerSourceReviewedInApprovedRepository = $false }
        $result = Invoke-BootstrapCase $c -CoverageOnly
        $result.state | Should -Be 'coverage-sources-prepared-read-only'
        $result.ruleCount | Should -Be 2
        $sources = Get-Content (Join-Path $c.root 'approved-sources.json') -Raw |
            ConvertFrom-Json -AsHashtable
        $sources.schemaVersion | Should -Be 7
        $sources.mode | Should -Be 'coverage-only'
        $sources.rules.Count | Should -Be 2
        $sources.rules.Contains('bpm-test-ownership@1') | Should -BeFalse
        $sources.rules.Contains('bpm-named-areequal-arguments@1') |
            Should -BeFalse
        $sources.rules['bpm-test-class-coverage@2'].policyLineHash |
            Should -Not -Be $sources.rules['bpm-redundant-method-coverage@2'].policyLineHash
        $sources.rules['bpm-test-class-coverage@2'].declarationDigest |
            Should -Not -Be $sources.rules['bpm-redundant-method-coverage@2'].declarationDigest
        (Get-Content (Join-Path $c.root 'provider-config.json') -Raw) |
            Should -Not -Match 'service@example.invalid'
        $c.state.reads[-1] | Should -Be 'GraphStorageKey'
    }
    It 'rejects source and identity drift before coverage receipt creation' {
        foreach ($failure in @('merge-content', 'master-content',
                'master-ref-drift', 'graph-upn', 'storage-key', 'principal-final')) {
            $c = Get-BootstrapCase
            $c.state.wrong = $failure
            { Invoke-BootstrapCase $c -CoverageOnly } |
                Should -Throw -Because $failure
            Test-Path $c.root | Should -BeFalse
        }
    }
    It 'rejects injected or swapped receipts without validating Owner/Named' {
        foreach ($failure in @('extra', 'swap', 'line', 'old-version')) {
            $c = Get-RegistryCase -CoverageOnly
            switch ($failure) {
                extra { $c.sources.rules['bpm-test-ownership@1'] = @{
                        approved = $true } }
                swap {
                    $a = $c.sources.rules['bpm-test-class-coverage@2']
                    $a.declarationDigest =
                        $c.sources.rules['bpm-redundant-method-coverage@2'].declarationDigest
                }
                line {
                    $c.sources.rules['bpm-test-class-coverage@2'].policyLineHash =
                        'v1:sha256:' + ('a' * 64)
                }
                'old-version' { $c.sources.schemaVersion = 6 }
            }
            { Invoke-RegistryCase $c } | Should -Throw -Because $failure
        }
    }
    It 'keeps the recorded source snapshot historical while proving a forward master' {
        $c = Get-RegistryCase -CoverageOnly
        $receipt = ConvertTo-Json -InputObject $c.sources -Depth 16 -Compress
        $c.case.state.master = 'f' * 40
        $c.case.state.reads.Clear()
        $registry = Invoke-RegistryCase $c
        $registry.schemaVersion | Should -Be 7
        $registry.currentMasterCommit | Should -Be ('f' * 40)
        $registry.rules.Count | Should -Be 2
        @($c.case.state.reads | Where-Object { $_ -ceq 'Commit' }).Count |
            Should -Be 5
        @($c.case.state.reads | Where-Object { $_ -ceq 'RawItem' }).Count |
            Should -Be 3
        (ConvertTo-Json -InputObject $c.sources -Depth 16 -Compress) |
            Should -BeExactly $receipt
        $c.sources.rules['bpm-test-class-coverage@2'].masterCommit |
            Should -Be ('e' * 40)
        $c.sources.rules['bpm-redundant-method-coverage@2'].masterCommit |
            Should -Be ('e' * 40)
        @($c.case.state.reads | Where-Object {
                $_ -in @('Write', 'Post', 'ListPage')
            }).Count | Should -Be 0
    }
    It 'retains the equal-tip fast path and reuses merge-pin ancestry' {
        $equal = Get-RegistryCase -CoverageOnly
        $equal.case.state.reads.Clear()
        (Invoke-RegistryCase $equal).currentMasterCommit | Should -Be ('e' * 40)
        @($equal.case.state.reads | Where-Object { $_ -ceq 'Commit' }).Count |
            Should -Be 2
        @($equal.case.state.reads | Where-Object { $_ -ceq 'RawItem' }).Count |
            Should -Be 2

        $merged = Get-RegistryCase -CoverageOnly
        $merged.case.state.master = 'f' * 40
        foreach ($rule in $merged.sources.rules.Values) {
            $rule.masterCommit = 'd' * 40
        }
        $merged.case.state.reads.Clear()
        (Invoke-RegistryCase $merged).currentMasterCommit | Should -Be ('f' * 40)
        @($merged.case.state.reads | Where-Object { $_ -ceq 'Commit' }).Count |
            Should -Be 3
        @($merged.case.state.reads | Where-Object { $_ -ceq 'RawItem' }).Count |
            Should -Be 2
    }
    It 'rejects rollback, unrelated or unproved source ancestry and changed bindings' {
        foreach ($failure in @('rollback', 'non-descendant', 'unknown-ancestry',
                'wrong-snapshot', 'different-snapshots', 'malformed-snapshot',
                'changed-blob', 'changed-snapshot', 'changed-line',
                'changed-declaration')) {
            $c = Get-RegistryCase -CoverageOnly
            switch ($failure) {
                rollback { $c.case.state.master = 'd' * 40 }
                'non-descendant' {
                    $c.case.state.master = 'f' * 40
                    $c.case.state.sourceLineage = 'non-descendant'
                }
                'unknown-ancestry' {
                    $c.case.state.master = 'f' * 40
                    $c.case.state.sourceLineage = 'malformed-after-proof'
                }
                'wrong-snapshot' {
                    foreach ($rule in $c.sources.rules.Values) {
                        $rule.masterCommit = 'a' * 40
                    }
                }
                'different-snapshots' {
                    $c.sources.rules['bpm-redundant-method-coverage@2'].masterCommit =
                        'f' * 40
                }
                'malformed-snapshot' {
                    $c.sources.rules['bpm-test-class-coverage@2'].masterCommit =
                        'not-a-commit'
                }
                'changed-blob' { $c.case.state.wrong = 'master-content' }
                'changed-snapshot' {
                    $c.case.state.master = 'f' * 40
                    $c.case.state.wrong = 'snapshot-content'
                }
                'changed-line' {
                    $c.sources.rules['bpm-test-class-coverage@2'].policyLineHash =
                        'v1:sha256:' + ('a' * 64)
                }
                'changed-declaration' {
                    $c.sources.rules['bpm-redundant-method-coverage@2'].declarationDigest =
                        'v1:sha256:' + ('a' * 64)
                }
            }
            $expected = switch ($failure) {
                { $_ -in @('rollback', 'non-descendant',
                        'unknown-ancestry', 'wrong-snapshot') } {
                    'coverage-source-master-lineage-unproved'
                }
                'changed-blob' { 'merged-master-document-drift' }
                'changed-snapshot' { 'coverage-source-snapshot-drift' }
                default { 'coverage-receipt-drift' }
            }
            { Invoke-RegistryCase $c } | Should -Throw "*$expected*" `
                -Because $failure
            @($c.case.state.reads | Where-Object {
                    $_ -in @('Write', 'Post', 'ListPage')
                }).Count | Should -Be 0
        }
    }
    It 'rechecks a larger bounded coverage source in the actual signed runner' {
        $c = Get-SignedIntakeCase -Code -CoverageOnly
        $c.state.content += '// ' + ('x' * 266240) + "`n"
        $c.state.lines = 4
        $bytes = [Text.Encoding]::UTF8.GetBytes($c.state.content)
        $header = [Text.Encoding]::ASCII.GetBytes("blob $($bytes.Length)`0")
        $c.state.objectId = [Convert]::ToHexString(
            [Security.Cryptography.SHA1]::HashData(
                [byte[]]($header + $bytes))).ToLowerInvariant()
        $signed = Invoke-SignedIntakeCase $c
        $signed.signed | Should -BeTrue
        $result = Invoke-RunnerCase $c
        $result.selected | Should -Be 2
        $result.writerEligible | Should -BeFalse
        $result.providerWrites | Should -Be 0
        @($result.rules | Where-Object {
                $_.capabilityId -in @('bpm-test-ownership@1',
                    'bpm-named-areequal-arguments@1') -and
                $_.reason -cne 'not-attempted'
            }).Count | Should -Be 0

        $oversized = Get-SignedIntakeCase -Code -CoverageOnly
        $oversized.state.content += '// ' + ('y' * 524288) + "`n"
        $oversized.state.lines = 4
        $bytes = [Text.Encoding]::UTF8.GetBytes($oversized.state.content)
        $header = [Text.Encoding]::ASCII.GetBytes("blob $($bytes.Length)`0")
        $oversized.state.objectId = [Convert]::ToHexString(
            [Security.Cryptography.SHA1]::HashData(
                [byte[]]($header + $bytes))).ToLowerInvariant()
        (Invoke-SignedIntakeCase $oversized).signed | Should -BeTrue
        { Invoke-RunnerCase $oversized } |
            Should -Throw '*canary-source-unverified*'
    }
    It 'signs advanced source master separately and rejects changes before private state' {
        $c = Get-SignedIntakeCase -Code -CoverageOnly
        $c.input.case.state.master = 'f' * 40
        $result = Invoke-SignedIntakeCase $c
        $result.signed | Should -BeTrue
        $config = Get-Content -LiteralPath (
            Join-Path $c.root 'canary-dispatcher.json') -Raw |
            ConvertFrom-Json -AsHashtable
        $config.schemaVersion | Should -Be 8
        $config.sourceMasterCommit | Should -Be ('f' * 40)
        $intakeConfig = Get-Content -LiteralPath (
            Join-Path $c.root 'canary-intake.json') -Raw |
            ConvertFrom-Json -AsHashtable
        $intakeConfig.limits.maxFileBytes | Should -Be 524288
        $intakeConfig.limits.maxTotalBytes | Should -Be 2097152
        $c.input.sources.rules['bpm-test-class-coverage@2'].masterCommit |
            Should -Be ('e' * 40)
        (Invoke-RunnerCase $c).selected | Should -Be 2

        $moving = Get-SignedIntakeCase -Code -CoverageOnly
        $prior = $moving.read
        $source = $moving.input.case.state
        $intake = $moving.state
        $moving.read = {
            param($operation, $request)
            if ($operation -ceq 'Ref' -and
                @($intake.calls | Where-Object { $_ -ceq 'ListPage' }).Count -gt 0) {
                $source.master = 'f' * 40
            }
            & $prior $operation $request
        }.GetNewClosure()
        $diagnostic = [ref]$null
        { Invoke-SignedIntakeCase $moving $diagnostic } |
            Should -Throw '*canary-source-drift*'
        $diagnostic.Value.failureCode | Should -Be 'canary-source-drift'
        $diagnostic.Value.privateIntakePersisted | Should -BeFalse
        Test-Path -LiteralPath $moving.root | Should -BeFalse
    }
    It 'reports the exact safe source preflight failure before inventory or state' {
        foreach ($failure in @('changed-receipt', 'unproved-snapshot',
                'changed-snapshot', 'changed-policy')) {
            $c = Get-SignedIntakeCase -Code -CoverageOnly
            switch ($failure) {
                'changed-receipt' {
                    $c.input.sources.rules['bpm-test-class-coverage@2'].policyLineHash =
                        'v1:sha256:' + ('a' * 64)
                }
                'unproved-snapshot' {
                    $c.input.case.state.master = 'f' * 40
                    $c.input.case.state.sourceLineage = 'non-descendant'
                }
                'changed-snapshot' {
                    $c.input.case.state.master = 'f' * 40
                    $c.input.case.state.wrong = 'snapshot-content'
                }
                'changed-policy' { $c.input.case.state.wrong = 'master-content' }
            }
            $expected = switch ($failure) {
                'changed-receipt' { 'coverage-receipt-drift' }
                'unproved-snapshot' { 'coverage-source-master-lineage-unproved' }
                'changed-snapshot' { 'coverage-source-snapshot-drift' }
                'changed-policy' { 'merged-master-document-drift' }
            }
            $diagnostic = [ref]$null
            { Invoke-SignedIntakeCase $c $diagnostic } |
                Should -Throw "*$expected*"
            $diagnostic.Value.failureCode | Should -Be $expected
            $diagnostic.Value.provider.attemptedCalls | Should -Be 0
            $c.input.case.state.reads.Count | Should -BeGreaterThan 0
            $diagnostic.Value.provider.totalAttemptedGets |
                Should -BeNullOrEmpty
            Test-Path -LiteralPath $c.root | Should -BeFalse
        }
    }
    It 'reports measured source-only GET counts before provider construction' {
        $sourceTelemetry = @{ attemptedGets = 19; completedGets = 19
            throttleEvents = 0; lastHttpStatus = $null }
        $diagnostic = & (Get-Module DevPilot.ActivePrCanary) {
            param($Telemetry)
            New-CanaryIntakeFailureDiagnostic $null @(7) $null `
                @{ attempted = 0; completed = 0 } $null $Telemetry
        } $sourceTelemetry
        $diagnostic.provider.totalAttemptedGets | Should -Be 19
        $diagnostic.provider.totalCompletedGets | Should -Be 19
        $diagnostic.provider.attemptedCalls | Should -Be 0
    }
    It 'signs a two-rule intake and evaluates only coverage rules' {
        $c = Get-SignedIntakeCase -Code -CoverageOnly
        $result = Invoke-SignedIntakeCase $c
        $result.signed | Should -BeTrue
        $result.rules.Count | Should -Be 4
        $config = Get-Content (Join-Path $c.root 'canary-dispatcher.json') -Raw |
            ConvertFrom-Json -AsHashtable
        $config.schemaVersion | Should -Be 8
        $config.mode | Should -Be 'coverage-only'
        $config.headProof | Should -Be 'iteration-source-current-target-v1'
        $config.sourceMasterCommit | Should -Be ('e' * 40)
        $config.heads[0].currentTargetCommit | Should -Be ('d' * 40)
        $config.heads[0].targetCommit | Should -Be ('b' * 40)
        $config.rules.Count | Should -Be 2
        $config.rules[0].policyLineHash | Should -Match '^v1:sha256:'
        $config.writerEligible | Should -BeFalse
        $evaluated = Invoke-RunnerCase $c
        $evaluated.kind | Should -Be 'private-coverage-only-read-only-evaluation'
        $evaluated.schemaVersion | Should -Be 8
        $evaluated.modelToolInvocations | Should -Be 0
        $evaluated.providerWrites | Should -Be 0
        $evaluated.writerEligible | Should -BeFalse
        ($evaluated.rules | Where-Object {
                $_.capabilityId -ceq 'bpm-test-class-coverage@2'
            }).wouldCreate | Should -Be 2
        @($evaluated.rules | Where-Object {
                $_.capabilityId -in @('bpm-test-ownership@1',
                    'bpm-named-areequal-arguments@1') -and
                ($_.unknown -ne $evaluated.selected -or
                    $_.evaluated -ne 0 -or $_.wouldCreate -ne 0 -or
                    $_.reason -cne 'not-attempted' -or
                    $_.status -cne 'unknown')
            }).Count | Should -Be 0
    }
    It 'signs only after both inclusive-echo passes prove selected coverage heads' {
        $c = Get-SignedIntakeCase -Code -CoverageOnly
        $inner = $c.provider
        $rows = $c.state.rows
        $c.provider = {
            param($operation, $request)
            $response = & $inner $operation $request
            if ($operation -ceq 'ListPage') {
                $echo = @($rows | Where-Object {
                        $_.creationDate -ceq $request.maxTime
                    })
                if ($echo.Count -eq 1) {
                    $response.items = @($echo[0]) + @(
                        $response.items | Select-Object -First ($request.top - 1))
                    $response.count = $response.items.Count
                }
            }
            return $response
        }.GetNewClosure()
        $signed = Invoke-SignedIntakeCase $c
        $signed.state | Should -Be 'signed-intake-not-evaluated'
        $signed.selected | Should -Be 2
        $signed.inventory.active | Should -Be 4
        $signed.inventory.eligible | Should -Be 2
        $signed.inventory.pagesFirst | Should -Be 3
        $signed.inventory.pagesSecond | Should -Be 3
        $signed.providerWrites | Should -Be 0
        $signed.writerEligible | Should -BeFalse
    }
    It 'does not create signed intake state for a changed boundary echo' {
        $c = Get-SignedIntakeCase -Code -CoverageOnly
        $inner = $c.provider
        $rows = $c.state.rows
        $c.provider = {
            param($operation, $request)
            $response = & $inner $operation $request
            if ($operation -ceq 'ListPage') {
                $echo = @($rows | Where-Object {
                        $_.creationDate -ceq $request.maxTime
                    })
                if ($echo.Count -eq 1) {
                    $changed = @{} + $echo[0]
                    $changed.targetRef = 'refs/heads/other'
                    $response.items = @($changed) + @($response.items)
                    $response.count = $response.items.Count
                }
            }
            return $response
        }.GetNewClosure()
        $diagnostic = [ref]$null
        { Invoke-SignedIntakeCase $c $diagnostic } |
            Should -Throw '*canary-inventory-unknown*'
        $diagnostic.Value.reasonCodes | Should -Contain 'keyset-changed-echo'
        $diagnostic.Value.selected[0].inventoryEligible | Should -BeNullOrEmpty
        $diagnostic.Value.privateIntakePersisted | Should -BeFalse
        Test-Path -LiteralPath $c.root | Should -BeFalse
    }
    It 'does not promote a legacy marker or a forged config to coverage authority' {
        $c = Get-SignedIntakeCase -Code -CoverageOnly
        [void](Invoke-SignedIntakeCase $c)
        $c.state.threads = @((New-RunnerThread $c 1 `
            ('<!-- devpilot-test-class-coverage:v1:' + ('a' * 64) + ' -->')))
        $result = Invoke-RunnerCase $c
        ($result.rules | Where-Object {
                $_.capabilityId -ceq 'bpm-test-class-coverage@2'
            }).wouldCreate | Should -Be 0
        ($result.rules | Where-Object {
                $_.capabilityId -ceq 'bpm-test-class-coverage@2'
            }).unknown | Should -BeGreaterThan 0
        Sign-RunnerConfig $c { param($config)
            $config.rules += @{
                capabilityId = 'bpm-test-ownership@1'; enabled = $false
                evaluated = $false; writerEligible = $false } }
        { Invoke-RunnerCase $c } | Should -Throw
    }
    It 'makes a mixed exact v2 and legacy v1 marker at one anchor unknown' {
        $c = Get-SignedIntakeCase -Code -CoverageOnly
        [void](Invoke-SignedIntakeCase $c)
        $exact = Get-RunnerClassMarkerBody $c
        $thread = New-RunnerThread $c 1 $exact
        $thread.comments += @{
            id = 2; author = $c.input.config.expectedAccount
            commentType = 'text'
            content = '<!-- devpilot-test-class-coverage:v1:' +
                ('a' * 64) + ' -->'
        }
        $c.state.threads = @($thread)
        $result = Invoke-RunnerCase $c
        $class = $result.rules | Where-Object {
            $_.capabilityId -ceq 'bpm-test-class-coverage@2'
        }
        $class.unknown | Should -Be $result.selected
        $class.evaluated | Should -Be 0
        $class.wouldCreate | Should -Be 0
        $result.providerWrites | Should -Be 0
    }
    It 'evaluates the redundant rule separately and treats its legacy marker as unknown' {
        $c = Get-SignedIntakeCase -Code -RedundantCode -CoverageOnly
        [void](Invoke-SignedIntakeCase $c)
        $result = Invoke-RunnerCase $c
        $redundant = $result.rules | Where-Object {
            $_.capabilityId -ceq 'bpm-redundant-method-coverage@2'
        }
        $redundant.wouldCreate | Should -Be $result.selected
        $c.state.threads = @(New-RunnerThread $c 1 (
                '<!-- devpilot-redundant-method-coverage:v1:' +
                ('a' * 64) + ' -->') -Line 7)
        $ambiguous = Invoke-RunnerCase $c
        $redundant = $ambiguous.rules | Where-Object {
            $_.capabilityId -ceq 'bpm-redundant-method-coverage@2'
        }
        $redundant.wouldCreate | Should -Be 0
        $redundant.unknown | Should -BeGreaterThan 0
    }
    It 'rejects incomplete graph and throttles before state creation' {
        foreach ($failure in @('unknown-project', 'throttle-changes',
                'split-page', 'stale-head', 'target-head-drift',
                'baseline-drift', 'iteration-baseline-drift',
                'invalid-live-target', 'retarget', 'alias-added', 'late-head')) {
            $c = Get-SignedIntakeCase -Code -CoverageOnly
            $c.state.wrong = $failure
            $diagnostic = [ref]$null
            { Invoke-SignedIntakeCase $c $diagnostic } | Should -Throw
            if ($failure -eq 'target-head-drift') {
                $diagnostic.Value.selected[0].reason | Should -Be 'head-drift'
                $diagnostic.Value.driftState | Should -Be 'detected'
            }
            Test-Path $c.root | Should -BeFalse
        }
    }
    It 'rejects changed or absent coverage live-target bindings even with a valid signature' {
        foreach ($mode in @('old-version', 'missing-proof', 'changed-pin',
                'missing-pin', 'changed-declaration', 'missing-source-master',
                'changed-source-master')) {
            $c = Get-SignedIntakeCase -Code -CoverageOnly
            [void](Invoke-SignedIntakeCase $c)
            switch ($mode) {
                'old-version' {
                    Sign-RunnerConfig $c { param($config)
                        $config.schemaVersion = 7
                        $config.Remove('sourceMasterCommit')
                    }
                }
                'missing-source-master' {
                    Sign-RunnerConfig $c { param($config)
                        $config.Remove('sourceMasterCommit')
                    }
                }
                'changed-source-master' {
                    Sign-RunnerConfig $c { param($config)
                        $config.sourceMasterCommit = 'f' * 40
                    }
                }
                'missing-proof' {
                    Sign-RunnerConfig $c { param($config)
                        $config.Remove('headProof')
                    }
                }
                'changed-pin' {
                    Sign-RunnerConfig $c { param($config)
                        $config.heads[0].currentTargetCommit = 'e' * 40
                    }
                }
                'missing-pin' {
                    Sign-RunnerConfig $c { param($config)
                        $config.heads[0].Remove('currentTargetCommit')
                    }
                }
                'changed-declaration' {
                    $root = Join-Path $c.root 'active-pr-intake-v1'
                    $path = Join-Path $root 'cohort.json'
                    $cohort = Get-Content -LiteralPath $path -Raw |
                        ConvertFrom-Json -AsHashtable -Depth 32
                    $cohort.heads[0].declaration.currentTargetCommit = 'e' * 40
                    $text = ConvertTo-Json -InputObject $cohort -Depth 32
                    [IO.File]::WriteAllText($path, $text)
                    [IO.File]::WriteAllText((Join-Path (
                            Join-Path $root 'generations') "$($cohort.generation).json"),
                        $text)
                }
            }
            { Invoke-RunnerCase $c } | Should -Throw -Because $mode
        }
    }
    It 'rejects a live source master shift after rule evaluation at the final check' {
        $c = Get-SignedIntakeCase -Code -CoverageOnly
        [void](Invoke-SignedIntakeCase $c)
        $prior = $c.read
        $source = $c.input.case.state
        $intake = $c.state
        $baseline = $intake.discussionVisits
        $c.read = {
            param($operation, $request)
            if ($operation -ceq 'Ref' -and
                $intake.discussionVisits -ge ($baseline + 4)) {
                $source.master = 'f' * 40
            }
            & $prior $operation $request
        }.GetNewClosure()
        { Invoke-RunnerCase $c } | Should -Throw '*canary-source-drift*'
        $intake.discussionVisits | Should -Be ($baseline + 4)
        $source.master | Should -Be ('f' * 40)
    }
    It 'rejects an unsigned change to the newly bound live source master' {
        $c = Get-SignedIntakeCase -Code -CoverageOnly
        [void](Invoke-SignedIntakeCase $c)
        Set-RunnerFile $c 'canary-dispatcher.json' {
            param($config)
            $config.sourceMasterCommit = 'f' * 40
        }
        $c.state.calls.Clear()
        { Invoke-RunnerCase $c } | Should -Throw '*canary-signature-invalid*'
        $c.state.calls.Count | Should -Be 0
    }
    It 'rejects a target change during coverage evaluation after signed intake' {
        $c = Get-SignedIntakeCase -Code -CoverageOnly
        [void](Invoke-SignedIntakeCase $c)
        $c.state.wrong = 'target-runner-drift'
        { Invoke-RunnerCase $c } | Should -Throw '*canary-head-drift*'
    }
    It 'rejects signature tampering before runner GET and head/discussion drift' {
        $c = Get-SignedIntakeCase -Code -CoverageOnly
        [void](Invoke-SignedIntakeCase $c)
        Set-RunnerFile $c 'canary-dispatcher.json' {
            param($config)
            $config.writerEligible = $true
        }
        $c.state.calls.Clear()
        { Invoke-RunnerCase $c } | Should -Throw '*canary-signature-invalid*'
        $c.state.calls.Count | Should -Be 0
        Sign-RunnerConfig $c {
            param($config)
            $config.writerEligible = $false
        }
        $c.state.wrong = 'stale-head'
        { Invoke-RunnerCase $c } | Should -Throw
        $c.state.wrong = 'discussion-drift'
        $c.state.threads = @(New-RunnerThread $c 1 'Exclude from code coverage.')
        $c.state.discussionVisits = 0
        { Invoke-RunnerCase $c } | Should -Throw '*canary-discussion-drift*'
    }
    It 'rechecks current merged source after evaluating the selected heads' {
        $c = Get-SignedIntakeCase -Code -CoverageOnly
        [void](Invoke-SignedIntakeCase $c)
        $previous = $c.read
        $source = $c.input.case.state
        $provider = $c.state
        $baseline = $provider.discussionVisits
        $c.read = {
            param($op, $request)
            if ($provider.discussionVisits -ge ($baseline + 4)) {
                $source.wrong = 'master-ref-drift'
            }
            & $previous $op $request
        }.GetNewClosure()
        { Invoke-RunnerCase $c } | Should -Throw
        $provider.discussionVisits | Should -Be ($baseline + 4)
    }
}
