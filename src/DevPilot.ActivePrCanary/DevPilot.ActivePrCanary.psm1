#requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1')
Import-Module (Join-Path $PSScriptRoot '..\DevPilot.ActivePrIntake\DevPilot.ActivePrIntake.psd1')
Import-Module (Join-Path $PSScriptRoot '..\DevPilot.RuleEvaluation\DevPilot.RuleEvaluation.psd1')

$script:OwnerCommit = 'f6db83436b48f48a8521095a888d79f67823bbb2'
$script:OwnerHash = 'bc31bfea6b378dffe4a1b28475dc1cac4cd3ee1ab793db57895446ded829ab2f'
$script:NamedSectionHash = 'b3935a2ac811353d1da72e9a310938679cf119963677bd2ebc90510aab85a03a'
$script:NamedSectionLength = 412
$script:DocumentPath = '/documentation/EngineeringProcesses/Conventions/AutomatedTests.md'
$script:CoverageCommit = '7e6620ec40c9bc37c5a5e13d506053b0139c9206'
$script:CoverageDocumentHash = '68a5cb1aa2604b971c8c446c77ef50f74409407f65eaa2e9389acd636cddacee'
$script:CoverageDocumentLength = 16286
$script:StaticPolicies = @(
    @{ name = 'class'; index = 1; file = 'test-class-coverage' },
    @{ name = 'redundant'; index = 2; file = 'redundant-method-coverage' },
    @{ name = 'named'; index = 3; file = 'named-areequal-arguments' }
)

function Get-CanaryHash {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    return [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
}

function Get-CanaryTextHash {
    param([AllowEmptyString()][string]$Text)
    return Get-CanaryHash ([Text.Encoding]::UTF8.GetBytes($Text))
}

function Assert-CanarySource {
    param([Collections.IDictionary]$Source, [string]$Path, [string]$Commit)
    if ($Source -isnot [Collections.IDictionary] -or
        $Source.approved -cne $true -or
        [string]$Source.projectName -cnotmatch '^[\w .-]{1,128}$' -or
        [string]$Source.repositoryName -cnotmatch '^[A-Za-z0-9._-]{1,128}$' -or
        [string]$Source.repositoryId -cnotmatch
            '^[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}$' -or
        [string]$Source.commit -cnotmatch '^[a-f0-9]{40}$' -or
        [string]$Source.path -cne $Path -or
        ($Commit -and [string]$Source.commit -cne $Commit)) {
        throw 'rule-source-not-approved'
    }
}

function Get-CanarySection {
    param([string]$Document, [string]$Heading)
    return (Get-CanaryRawSection $Document $Heading).Trim()
}

function Get-CanaryRawSection {
    param([string]$Document, [string]$Heading)
    $pattern = '(?m)^' + [regex]::Escape($Heading) +
        '[ \t]*(?:\r\n|\n|\r)(?:(?!^##[ \t]).)*(?=^##[ \t]|\z)'
    $sections = [regex]::Matches($Document, $pattern,
        [Text.RegularExpressions.RegexOptions]::Singleline -bor
        [Text.RegularExpressions.RegexOptions]::Multiline)
    if ($sections.Count -ne 1) { throw 'rule-section-unavailable' }
    return $sections[0].Value
}

function Read-CanarySource {
    param([scriptblock]$Provider, [Collections.IDictionary]$Source, [string]$Path)
    $result = & $Provider RuleSource @{
        projectName = $Source.projectName
        repositoryName = $Source.repositoryName
        repositoryId = $Source.repositoryId
        commit = $Source.commit
        path = $Path
    }
    if ($result -isnot [Collections.IDictionary] -or
        $result.content -isnot [string] -or
        [string]$result.projectName -cne [string]$Source.projectName -or
        [string]$result.repositoryName -cne [string]$Source.repositoryName -or
        [string]$result.repositoryId -ine [string]$Source.repositoryId -or
        [string]$result.commit -cne [string]$Source.commit -or
        [string]$result.path -cne $Path -or
        [Text.Encoding]::UTF8.GetByteCount($result.content) -gt 262144) {
        throw 'rule-source-mismatch'
    }
    return [string]$result.content
}

function Get-CanaryCoverageDeclarations {
    param([string]$Document, [string]$RepositoryId)
    $lines = [regex]::Split($Document, '\r\n|\n|\r')
    if ($lines.Count -lt 223) { throw 'coverage-source-section-mismatch' }
    $headingIndex = -1
    for ($i = 0; $i -lt 220; $i++) {
        if ($lines[$i] -cmatch '^## [^\r\n]+$') { $headingIndex = $i }
    }
    if ($headingIndex -lt 0 -or
        @($lines[220..222] | Where-Object { $_ -cmatch '^## ' }).Count -ne 0) {
        throw 'coverage-source-section-mismatch'
    }
    $heading = $lines[$headingIndex]
    $sectionHash = 'v1:sha256:' +
        (Get-CanaryTextHash (Get-CanarySection $Document $heading))
    $ruleIds = @('bpm-test-class-coverage@2',
        'bpm-redundant-method-coverage@2')
    return @(
        for ($i = 0; $i -lt 2; $i++) {
            $line = @(221, 223)[$i]
            $declaration = [ordered]@{
                ruleId = $ruleIds[$i]
                repositoryId = $RepositoryId.ToLowerInvariant()
                commit = $script:CoverageCommit
                path = $script:DocumentPath.Substring(1)
                section = $heading
                sectionHash = $sectionHash
                policyLine = $line
                policyLineHash = 'v1:sha256:' + (Get-CanaryTextHash $lines[$line - 1])
            }
            [ordered]@{
                ruleId = $ruleIds[$i]
                declarationDigest = 'v1:sha256:' + (Get-CanaryTextHash (
                        ConvertTo-AgentCanonicalJson -InputObject $declaration))
                sectionHash = $sectionHash
                policyLine = $line
                policyLineHash = $declaration.policyLineHash
                section = $heading
            }
        }
    )
}

function Assert-CanaryCoverageSource {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$ApprovedSources,
        [Parameter(Mandatory)][scriptblock]$Provider,
        [switch]$Run
    )
    if (-not $Run) {
        return [ordered]@{ state = 'disabled'; headVerified = $false
            providerReads = 0; providerWrites = 0 }
    }
    $ruleIds = @('bpm-test-class-coverage@2',
        'bpm-redundant-method-coverage@2')
    $sources = @($ApprovedSources[$ruleIds[0]], $ApprovedSources[$ruleIds[1]])
    foreach ($i in 0..1) {
        $source = $sources[$i]
        Assert-CanarySource $source $script:DocumentPath $script:CoverageCommit
        if ([string]$source.ruleId -cne $ruleIds[$i] -or
            [string]$source.projectName -cne 'Engineering' -or
            [string]$source.repositoryName -cne 'EngHub' -or
            [string]$source.provenance -cne 'unmerged-reviewed-pr' -or
            [string]$source.reviewedPullRequestId -cne '17307009' -or
            [string]$source.reviewedHead -cne $script:CoverageCommit -or
            [string]$source.documentHash -cne
                ('v1:sha256:' + $script:CoverageDocumentHash) -or
            [string]$source.declarationDigest -cnotmatch '^v1:sha256:[a-f0-9]{64}$') {
            throw 'coverage-source-not-approved'
        }
    }
    if ([string]$sources[0].repositoryId -ine [string]$sources[1].repositoryId) {
        throw 'coverage-source-identity-mismatch'
    }
    $document = Read-CanarySource $Provider $sources[0] $script:DocumentPath
    $bytes = [Text.Encoding]::UTF8.GetBytes($document)
    if ($bytes.Length -ne $script:CoverageDocumentLength -or
        (Get-CanaryHash $bytes) -cne $script:CoverageDocumentHash) {
        throw 'coverage-source-bytes-mismatch'
    }
    $declarations = @(Get-CanaryCoverageDeclarations $document `
            ([string]$sources[0].repositoryId))
    for ($i = 0; $i -lt 2; $i++) {
        if ([string]$sources[$i].declarationDigest -cne
            $declarations[$i].declarationDigest) {
            throw 'coverage-declaration-digest-mismatch'
        }
    }
    return [ordered]@{
        schemaVersion = 1
        state = 'immutable-candidate-only'
        provenance = 'unmerged-reviewed-pr'
        reviewCaution = 'pending-human-review; not-master-authority'
        reviewedPullRequestId = 17307009
        reviewedHead = $script:CoverageCommit
        headVerified = $false
        repositoryId = ([string]$sources[0].repositoryId).ToLowerInvariant()
        commit = $script:CoverageCommit
        path = $script:DocumentPath.Substring(1)
        documentHash = 'v1:sha256:' + $script:CoverageDocumentHash
        declarations = @($declarations | ForEach-Object {
                [ordered]@{ ruleId = $_.ruleId
                    declarationDigest = $_.declarationDigest
                    sectionHash = $_.sectionHash; policyLine = $_.policyLine }
            })
    }
}

function Write-CanaryPrivateFile {
    param([string]$Path, [byte[]]$Bytes)
    $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew,
        [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        if (-not $IsWindows) {
            [IO.File]::SetUnixFileMode($Path, (
                [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite))
        }
        $stream.Write($Bytes, 0, $Bytes.Length)
        $stream.Flush($true)
    }
    finally { $stream.Dispose() }
}

function Get-CanaryGitValue {
    param([string]$RepositoryRoot, [string[]]$Arguments)
    try { $answer = & git -C $RepositoryRoot @Arguments 2>$null }
    catch { throw 'local-rule-source-unavailable' }
    if ($LASTEXITCODE -ne 0 -or @($answer).Count -ne 1 -or
        [string]$answer -cnotmatch '^[a-f0-9]{40}$') {
        throw 'local-rule-source-unavailable'
    }
    return [string]$answer
}

function Get-CanaryGitRepository {
    param([string]$RepositoryRoot)
    try { $url = & git -C $RepositoryRoot remote get-url origin 2>$null }
    catch { throw 'local-rule-source-unavailable' }
    if ($LASTEXITCODE -ne 0 -or @($url).Count -ne 1 -or
        [string]$url -cnotmatch
            '^(?:https://github\.com/|git@github\.com:)(?<owner>[A-Za-z0-9._-]+)/(?<repo>[A-Za-z0-9._-]+?)(?:\.git)?$') {
        throw 'local-rule-source-unavailable'
    }
    return "$($Matches.owner)/$($Matches.repo)"
}

function Get-CanaryAadToken {
    param([string]$AzureCliPath, [string]$Resource)
    if ($Resource -cnotmatch
        '^https://[A-Za-z0-9-]+\.vssps\.visualstudio\.com/?$') {
        throw 'bootstrap-credential-unavailable'
    }
    try {
        $command = Get-Command $AzureCliPath -CommandType Application,ExternalScript `
            -ErrorAction Stop | Select-Object -First 1
        $response = & $command.Source account get-access-token --resource `
            $Resource --output json `
            --only-show-errors 2>$null
        if ($LASTEXITCODE -ne 0) { throw 'bootstrap-credential-unavailable' }
        $credential = $response | ConvertFrom-Json -AsHashtable -Depth 8
        if ($credential.tokenType -ine 'Bearer' -or
            [string]$credential.accessToken -cnotmatch
                '^[A-Za-z0-9._~+/-]{40,8192}(?:={0,2})$') {
            throw 'bootstrap-credential-unavailable'
        }
        return [string]$credential.accessToken
    }
    catch { throw 'bootstrap-credential-unavailable' }
}

function Invoke-CanaryAadGet {
    param([Net.Http.HttpClient]$Client, [string]$Token, [string]$Organization,
        [string]$Operation, [Collections.IDictionary]$Request,
        [DateTime]$Deadline)
    $guid = '^[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}$'
    $sha = '^[a-f0-9]{40}$'
    $project = [string]$Request['projectName']
    $repository = [string]$Request['repositoryId']
    $commit = [string]$Request['commit']
    $path = [string]$Request['path']
    $esc = [Uri]::EscapeDataString
    $base = "https://dev.azure.com/$Organization"
    $url = switch -CaseSensitive ($Operation) {
        Identity { "$base/_apis/connectionData?api-version=7.1-preview.1" }
        Project {
            if ($project -cnotmatch '^[\w .-]{1,128}$' -or
                $project -in @('.', '..')) {
                throw 'bootstrap-request-invalid'
            }
            "$base/_apis/projects/$($esc.Invoke($project))?api-version=7.1"
        }
        Repository {
            if ($project -cnotmatch '^[\w .-]{1,128}$' -or
                $project -in @('.', '..') -or
                [string]$Request.repositoryName -cnotmatch
                    '^[A-Za-z0-9._-]{1,128}$' -or
                [string]$Request.repositoryName -in @('.', '..')) {
                throw 'bootstrap-request-invalid'
            }
            "$base/$($esc.Invoke($project))/_apis/git/repositories/" +
                "$($esc.Invoke([string]$Request.repositoryName))?api-version=7.1"
        }
        PullRequest {
            if ($project -cnotmatch '^[\w .-]{1,128}$' -or
                $repository -cnotmatch $guid) { throw 'bootstrap-request-invalid' }
            "$base/$($esc.Invoke($project))/_apis/git/repositories/$repository/" +
                'pullRequests/17307009?api-version=7.1'
        }
        Iterations {
            if ($project -cnotmatch '^[\w .-]{1,128}$' -or
                $repository -cnotmatch $guid) { throw 'bootstrap-request-invalid' }
            "$base/$($esc.Invoke($project))/_apis/git/repositories/$repository/" +
                'pullRequests/17307009/iterations?api-version=7.1'
        }
        Ref {
            if ($project -cnotmatch '^[\w .-]{1,128}$' -or
                $repository -cnotmatch $guid -or
                [string]$Request.sourceRef -cnotmatch
                    '^refs/heads/[A-Za-z0-9._/-]{1,512}$') {
                throw 'bootstrap-request-invalid'
            }
            "$base/$($esc.Invoke($project))/_apis/git/repositories/$repository/" +
                "refs?filter=$($esc.Invoke(([string]$Request.sourceRef).Substring(5)))" +
                '&$top=100&api-version=7.1'
        }
        Commit {
            if ($project -cnotmatch '^[\w .-]{1,128}$' -or
                $repository -cnotmatch $guid -or $commit -cnotmatch $sha) {
                throw 'bootstrap-request-invalid'
            }
            "$base/$($esc.Invoke($project))/_apis/git/repositories/$repository/" +
                "commits/$commit`?api-version=7.1"
        }
        { $_ -cin @('Item', 'RawItem') } {
            if ($project -cnotmatch '^[\w .-]{1,128}$' -or
                $repository -cnotmatch $guid -or $commit -cnotmatch $sha -or
                $path -cne $script:DocumentPath) {
                throw 'bootstrap-request-invalid'
            }
            "$base/$($esc.Invoke($project))/_apis/git/repositories/$repository/" +
                "items?path=$($esc.Invoke($path))&versionDescriptor.version=$commit" +
                '&versionDescriptor.versionType=commit&' +
                $(if ($Operation -ceq 'Item') {
                        'includeContent=false&includeContentMetadata=true&'
                    } else { '' }) + 'api-version=7.1'
        }
        default { throw 'bootstrap-request-invalid' }
    }
    $limit = if ($Operation -ceq 'RawItem') { 262144 } else { 65536 }
    $message = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get, $url)
    $message.Headers.Authorization =
        [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $Token)
    $message.Headers.Accept.ParseAdd($(if ($Operation -ceq 'RawItem') {
                'application/octet-stream'
            } else { 'application/json' }))
    $remaining = [Math]::Max(1, [int]($Deadline - [DateTime]::UtcNow).TotalMilliseconds)
    $cancel = [Threading.CancellationTokenSource]::new($remaining)
    try {
        $response = $Client.SendAsync($message,
            [Net.Http.HttpCompletionOption]::ResponseHeadersRead,
            $cancel.Token).GetAwaiter().GetResult()
        try {
            if (-not $response.IsSuccessStatusCode -or
                ($null -ne $response.Content.Headers.ContentLength -and
                    $response.Content.Headers.ContentLength -gt $limit)) {
                throw 'bootstrap-read-inaccessible'
            }
            $stream = $response.Content.ReadAsStreamAsync(
                $cancel.Token).GetAwaiter().GetResult()
            $output = [IO.MemoryStream]::new()
            $buffer = [byte[]]::new(8192)
            try {
                while (($n = $stream.ReadAsync($buffer, 0, $buffer.Length,
                            $cancel.Token).GetAwaiter().GetResult()) -gt 0) {
                    if ($output.Length + $n -gt $limit) {
                        throw 'bootstrap-read-inaccessible'
                    }
                    $output.Write($buffer, 0, $n)
                }
                $bytes = $output.ToArray()
            }
            finally { $output.Dispose() }
        }
        finally { $response.Dispose() }
        if ($Operation -ceq 'RawItem') { return @{ bytes = $bytes } }
        $result = [Text.UTF8Encoding]::new($false, $true).GetString($bytes) |
            ConvertFrom-Json -AsHashtable -Depth 12
        if ($Operation -ceq 'Identity') {
            return @{ id = $result.authenticatedUser.id
                descriptor = $result.authenticatedUser.subjectDescriptor
                uniqueName = $result.authenticatedUser.uniqueName }
        }
        return $result
    }
    catch { throw 'bootstrap-read-inaccessible' }
    finally {
        $cancel.Dispose()
        $message.Dispose()
    }
}

function Assert-CanaryBootstrapHead {
    param([scriptblock]$Read, [string]$RepositoryId, [string]$ProjectId)
    $request = @{ projectName = 'Engineering'; repositoryId = $RepositoryId }
    $pr = & $Read PullRequest $request
    $iterations = & $Read Iterations $request
    if ($pr -isnot [Collections.IDictionary] -or
        [string]$pr.pullRequestId -cne '17307009' -or
        [string]$pr.repository.id -ine $RepositoryId -or
        [string]$pr.repository.project.id -ine $ProjectId -or
        [string]$pr.repository.project.name -cne 'Engineering' -or
        [string]$pr.status -cne 'active' -or
        [string]$pr.sourceRefName -cnotmatch
            '^refs/heads/[A-Za-z0-9._/-]{1,512}$' -or
        $iterations.value -isnot [array] -or
        $iterations.value.Count -lt 1 -or $iterations.value.Count -gt 200) {
        throw 'coverage-pr-head-unverified'
    }
    $seen = [Collections.Generic.HashSet[int]]::new()
    foreach ($iteration in $iterations.value) {
        $id = 0
        if ($iteration -isnot [Collections.IDictionary] -or
            -not [int]::TryParse([string]$iteration.id, [ref]$id) -or
            $id -lt 1 -or -not $seen.Add($id) -or
            [string]$iteration.sourceRefCommit.commitId -cnotmatch
                '^[a-fA-F0-9]{40}$') {
            throw 'coverage-pr-head-unverified'
        }
    }
    $latest = @($iterations.value | Sort-Object { [int]$_.id } |
        Select-Object -Last 1)[0]
    if ([string]$pr.lastMergeSourceCommit.commitId -ine $script:CoverageCommit -or
        [string]$latest.sourceRefCommit.commitId -ine $script:CoverageCommit -or
        [string]$latest.id -cnotmatch '^[1-9][0-9]*$') {
        throw 'coverage-pr-head-unverified'
    }
    $refs = & $Read Ref (@{ projectName = 'Engineering'
            repositoryId = $RepositoryId; sourceRef = $pr.sourceRefName })
    $matched = @($refs.value | Where-Object name -CEQ $pr.sourceRefName)
    if ($refs.value -isnot [array] -or $refs.value.Count -gt 100 -or
        $matched.Count -ne 1 -or
        [string]$matched[0].objectId -ine $script:CoverageCommit) {
        throw 'coverage-pr-head-unverified'
    }
}

function Invoke-PrivateCanaryBootstrap {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Organization,
        [Parameter(Mandatory)][string]$ProjectName,
        [Parameter(Mandatory)][string]$RepositoryName,
        [Parameter(Mandatory)][string]$ExpectedAccountUniqueName,
        [Parameter(Mandatory)][string]$StateRoot,
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [string]$AzureCliPath = 'az',
        [scriptblock]$Read,
        [switch]$Run
    )
    if ($Organization -cnotmatch '^[A-Za-z0-9_-]{1,128}$' -or
        $ProjectName -cnotmatch '^[\w .-]{1,128}$' -or
        $ProjectName -in @('.', '..') -or
        $RepositoryName -cnotmatch '^[A-Za-z0-9._-]{1,128}$' -or
        $RepositoryName -in @('.', '..') -or
        $ExpectedAccountUniqueName -cnotmatch '^[^@\s]+@[^@\s]+$' -or
        -not [IO.Path]::IsPathFullyQualified($StateRoot) -or
        -not [IO.Path]::IsPathFullyQualified($RepositoryRoot) -or
        (Test-AgentPathWithin $StateRoot $RepositoryRoot)) {
        throw 'bootstrap-input-invalid'
    }
    if (Test-Path -LiteralPath $StateRoot) {
        throw 'canary-state-root-must-be-new'
    }
    if (-not $Run) {
        return [ordered]@{ state = 'disabled'; providerReads = 0
            providerWrites = 0; signed = $false }
    }
    $client = $null
    try {
        if (-not $Read) {
            $template = Get-Content -LiteralPath (Join-Path $RepositoryRoot `
                    'samples\active-pr-intake.config.json') -Raw |
                ConvertFrom-Json -AsHashtable
            $token = Get-CanaryAadToken $AzureCliPath `
                ([string]$template.identityResource)
            $handler = [Net.Http.HttpClientHandler]::new()
            $handler.AllowAutoRedirect = $false
            $client = [Net.Http.HttpClient]::new($handler)
            $client.Timeout = [TimeSpan]::FromSeconds(120)
            $readOrg = $Organization
            $readToken = $token
            $readClient = $client
            $readDeadline = [DateTime]::UtcNow.AddSeconds(120)
            $aadGet = ${function:Invoke-CanaryAadGet}
            $Read = {
                param($Operation, $Request)
                & $aadGet $readClient $readToken $readOrg `
                    $Operation $Request $readDeadline
            }.GetNewClosure()
        }
        $reads = 0
        $bounded = {
            param($Operation, $Request)
            if ($reads -ge 20) { throw 'bootstrap-read-budget' }
            $reads++
            $result = & $Read $Operation $Request
            if ($result -isnot [Collections.IDictionary]) {
                throw 'bootstrap-read-inaccessible'
            }
            return $result
        }.GetNewClosure()
        $identity = & $bounded Identity @{}
        if ([string]$identity.id -cnotmatch
                '^[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}$' -or
            [string]$identity.descriptor -cnotmatch '^\S{1,512}$' -or
            [string]$identity.uniqueName -ine $ExpectedAccountUniqueName) {
            throw 'bootstrap-principal-mismatch'
        }
        $project = & $bounded Project @{ projectName = $ProjectName }
        $repository = & $bounded Repository @{
            projectName = $ProjectName; repositoryName = $RepositoryName }
        $engineering = & $bounded Project @{ projectName = 'Engineering' }
        $enghub = & $bounded Repository @{
            projectName = 'Engineering'; repositoryName = 'EngHub' }
        $guid = '^[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}$'
        if ([string]$project.id -cnotmatch $guid -or
            [string]$project.name -cne $ProjectName -or
            [string]$repository.id -cnotmatch $guid -or
            [string]$repository.name -cne $RepositoryName -or
            [string]$repository.project.id -ine [string]$project.id -or
            [string]$repository.project.name -cne $ProjectName -or
            [string]$engineering.id -cnotmatch $guid -or
            [string]$engineering.name -cne 'Engineering' -or
            [string]$enghub.id -cnotmatch $guid -or
            [string]$enghub.name -cne 'EngHub' -or
            [string]$enghub.project.id -ine [string]$engineering.id -or
            [string]$enghub.project.name -cne 'Engineering') {
            throw 'bootstrap-repository-mismatch'
        }
        $engId = ([string]$enghub.id).ToLowerInvariant()
        Assert-CanaryBootstrapHead $bounded $engId ([string]$engineering.id)
        $commit = & $bounded Commit @{
            projectName = 'Engineering'; repositoryId = $engId
            commit = $script:CoverageCommit }
        if ([string]$commit.commitId -ine $script:CoverageCommit) {
            throw 'coverage-commit-unverified'
        }
        $documentPath = $script:DocumentPath
        $readDocument = {
            param([string]$Revision)
            $request = @{ projectName = 'Engineering'; repositoryId = $engId
                path = $documentPath; commit = $Revision }
            $item = & $bounded Item $request
            if ([string]$item.path -cne $documentPath -or
                [string]$item.objectId -cnotmatch '^[a-fA-F0-9]{40}$' -or
                [string]$item.gitObjectType -cne 'blob' -or
                $item['isFolder'] -eq $true -or $item['isSymLink'] -eq $true) {
                throw 'bootstrap-blob-unverified'
            }
            $raw = & $bounded RawItem $request
            if ($raw.bytes -isnot [byte[]] -or $raw.bytes.Length -gt 262144) {
                throw 'bootstrap-blob-unverified'
            }
            $bytes = [byte[]]$raw.bytes
            $header = [Text.Encoding]::ASCII.GetBytes("blob $($bytes.Length)`0")
            $oid = [Convert]::ToHexString(
                [Security.Cryptography.SHA1]::HashData(
                    [byte[]]($header + $bytes))).ToLowerInvariant()
            if ($oid -ine [string]$item.objectId) {
                throw 'bootstrap-blob-unverified'
            }
            try {
                return @{ text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
                    blobId = $oid }
            }
            catch { throw 'bootstrap-blob-unverified' }
        }.GetNewClosure()
        $ownerSource = & $readDocument $script:OwnerCommit
        $ownerSection = Get-CanarySection $ownerSource.text '## Claim ownership'
        $namedSection = Get-CanaryRawSection $ownerSource.text `
            '## Named parameters for Assert'
        if ((Get-CanaryTextHash $ownerSection) -cne $script:OwnerHash -or
            (Get-CanaryTextHash $namedSection) -cne $script:NamedSectionHash -or
            [Text.Encoding]::UTF8.GetByteCount($namedSection) -ne
                $script:NamedSectionLength) {
            throw 'bootstrap-section-mismatch'
        }
        $coverageSource = & $readDocument $script:CoverageCommit
        $coverageBytes = [Text.Encoding]::UTF8.GetBytes($coverageSource.text)
        if ($coverageBytes.Length -ne $script:CoverageDocumentLength -or
            (Get-CanaryHash $coverageBytes) -cne $script:CoverageDocumentHash) {
            throw 'coverage-source-bytes-mismatch'
        }
        $declarations = @(Get-CanaryCoverageDeclarations $coverageSource.text $engId)
        Assert-CanaryBootstrapHead $bounded $engId ([string]$engineering.id)
        $finalIdentity = & $bounded Identity @{}
        if ([string]$finalIdentity.id -ine [string]$identity.id -or
            [string]$finalIdentity.descriptor -cne [string]$identity.descriptor -or
            [string]$finalIdentity.uniqueName -ine [string]$identity.uniqueName) {
            throw 'bootstrap-principal-mismatch'
        }
        $policyPath = 'src/DevPilot.OwnerCapability/Policy/named-areequal-arguments.v1.txt'
        $localPath = Join-Path $RepositoryRoot (
            $policyPath -replace '/', [IO.Path]::DirectorySeparatorChar)
        $local = [IO.File]::ReadAllBytes($localPath)
        $localCommit = Get-CanaryGitValue $RepositoryRoot @('rev-parse', 'HEAD')
        if ($local.Length -gt 65536 -or
            (Get-CanaryGitValue $RepositoryRoot @(
                    'rev-parse', "${localCommit}:$policyPath")) -cne
            (Get-CanaryGitValue $RepositoryRoot @('hash-object', '--', $policyPath)) -or
            (Get-CanaryGitValue $RepositoryRoot @('rev-parse', 'HEAD')) -cne
                $localCommit) {
            throw 'local-rule-source-unavailable'
        }
        $localRepository = Get-CanaryGitRepository $RepositoryRoot
        $providerConfig = [ordered]@{
            provider = 'AzureDevOps'
            repository = [ordered]@{
                organization = $Organization; project = $ProjectName
                name = $RepositoryName
                id = ([string]$repository.id).ToLowerInvariant()
            }
            projectId = ([string]$project.id).ToLowerInvariant()
            expectedAccount = [ordered]@{
                id = ([string]$identity.id).ToLowerInvariant()
                descriptor = [string]$identity.descriptor
                uniqueName = [string]$identity.uniqueName
            }
            operator = [ordered]@{
                defaultAlias = [string]$identity.uniqueName
            }
        }
        $engSource = [ordered]@{
            projectName = 'Engineering'; repositoryName = 'EngHub'
            repositoryId = $engId; path = $script:DocumentPath
        }
        $owner = [ordered]@{} + $engSource
        $owner.approved = $true
        $owner.commit = $script:OwnerCommit
        $owner.section = '## Claim ownership'
        $owner.sectionHash = 'v1:sha256:' + $script:OwnerHash
        $owner.blobId = $ownerSource.blobId
        $owner.sectionLength = [Text.Encoding]::UTF8.GetByteCount($ownerSection)
        $owner.declarationDigest = 'v1:sha256:' + (Get-CanaryTextHash (
                ConvertTo-AgentCanonicalJson -InputObject ([ordered]@{
                        ruleId = 'bpm-test-ownership@1'; repositoryId = $engId
                        commit = $script:OwnerCommit; path = $script:DocumentPath
                        sectionHash = $owner.sectionHash
                        sectionLength = $owner.sectionLength
                    })))
        $namedSectionSource = [ordered]@{} + $engSource
        $namedSectionSource.approved = $true
        $namedSectionSource.commit = $script:OwnerCommit
        $namedSectionSource.section = '## Named parameters for Assert'
        $namedSectionSource.sectionHash = 'v1:sha256:' + $script:NamedSectionHash
        $namedSectionSource.blobId = $ownerSource.blobId
        $namedSectionSource.sectionLength = $script:NamedSectionLength
        $rules = [ordered]@{}
        for ($i = 0; $i -lt 2; $i++) {
            $source = [ordered]@{} + $engSource
            $source.approved = $true
            $source.ruleId = $declarations[$i].ruleId
            $source.commit = $script:CoverageCommit
            $source.provenance = 'unmerged-reviewed-pr'
            $source.reviewedPullRequestId = 17307009
            $source.reviewedHead = $script:CoverageCommit
            $source.headVerified = $true
            $source.documentHash = 'v1:sha256:' + $script:CoverageDocumentHash
            $source.blobId = $coverageSource.blobId
            $source.section = $declarations[$i].section
            $source.sectionHash = $declarations[$i].sectionHash
            $source.policyLine = $declarations[$i].policyLine
            $source.policyLineHash = $declarations[$i].policyLineHash
            $source.declarationDigest = $declarations[$i].declarationDigest
            $rules[$declarations[$i].ruleId] = $source
        }
        $rules['bpm-test-ownership@1'] = $owner
        $namedRule = [ordered]@{
            approved = $true; provenance = 'repository-local-commit'
            ruleRepository = $localRepository
            commit = $localCommit; path = $policyPath
            policyHash = 'v1:sha256:' + (Get-CanaryHash $local)
            capabilityDigest = 'v1:sha256:' +
                (Get-CanaryTextHash 'named-areequal-arguments-capability-v1')
            namedSectionHash = 'v1:sha256:' + $script:NamedSectionHash
        }
        $namedRule.declarationDigest = 'v1:sha256:' + (Get-CanaryTextHash (
                ConvertTo-AgentCanonicalJson -InputObject ([ordered]@{
                        ruleId = 'bpm-named-areequal-arguments@1'
                        ruleRepository = $namedRule.ruleRepository
                        commit = $localCommit; path = $policyPath
                        policyHash = $namedRule.policyHash
                        namedSectionHash = $namedRule.namedSectionHash
                        capabilityDigest = $namedRule.capabilityDigest
                    })))
        $rules['bpm-named-areequal-arguments@1'] = $namedRule
        $manifest = [ordered]@{
            schemaVersion = 2; kind = 'private-read-only-canary-sources'
            sourceAuthority = 'unmerged-reviewed-pr-is-candidate-only'
            verifiedUtc = [DateTime]::UtcNow.ToString('o')
            namedSection = $namedSectionSource
            rules = $rules
        }
        $created = $false
        $root = Resolve-AgentTrustedRoot -Path $StateRoot -Kind durable-state `
            -RepositoryRoot $RepositoryRoot -Create -CreatedByCaller ([ref]$created)
        if (-not $created) { throw 'canary-state-root-must-be-new' }
        foreach ($entry in @(
                @{ name = 'provider-config.json'; value = $providerConfig },
                @{ name = 'approved-sources.json'; value = $manifest })) {
            $file = Join-Path $root $entry.name
            Write-CanaryPrivateFile $file ([Text.Encoding]::UTF8.GetBytes(
                    (ConvertTo-Json -InputObject $entry.value -Depth 16)))
            [void](Assert-AgentTrustedFile -Path $file -AllowedRoot $root -Private)
        }
        return [ordered]@{
            state = 'prepared-read-only'; signed = $false
            canaryExecuted = $false; providerReads = $reads; providerWrites = 0
            ruleCount = 4; candidateCount = 2
            documentHash = 'v1:sha256:' + $script:CoverageDocumentHash
            localCommit = $localCommit
        }
    }
    finally { if ($client) { $client.Dispose() } }
}

function Invoke-ActivePrCanaryQualification {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$ProviderConfig,
        [Parameter(Mandatory)][Collections.IDictionary]$ApprovedSources,
        [Parameter(Mandatory)][string]$StateRoot,
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][int[]]$CanaryPullRequestIds,
        [string]$AzureCliPath = 'az',
        [scriptblock]$Provider,
        [switch]$Run
    )
    if ($CanaryPullRequestIds.Count -lt 1 -or $CanaryPullRequestIds.Count -gt 2 -or
        @($CanaryPullRequestIds | Where-Object { $_ -lt 1 }).Count -gt 0 -or
        @($CanaryPullRequestIds | Select-Object -Unique).Count -ne
            $CanaryPullRequestIds.Count) { throw 'invalid-canary-selection' }
    if (-not [IO.Path]::IsPathFullyQualified($RepositoryRoot) -or
        -not [IO.Path]::IsPathFullyQualified($StateRoot) -or
        (Test-AgentPathWithin -Path $StateRoot -Root $RepositoryRoot)) {
        throw 'state-root-must-be-external'
    }
    if (Test-Path -LiteralPath $StateRoot) { throw 'canary-state-root-must-be-new' }
    $repository = $ProviderConfig['repository']
    $account = $ProviderConfig['expectedAccount']
    $alias = [string]$ProviderConfig.operator.defaultAlias
    if ($ProviderConfig.provider -cne 'AzureDevOps' -or
        $repository -isnot [Collections.IDictionary] -or
        [string]$repository.organization -cnotmatch '^[A-Za-z0-9_-]{1,128}$' -or
        [string]$repository.project -cnotmatch '^[\w .-]{1,128}$' -or
        [string]$repository.name -cnotmatch '^[A-Za-z0-9._-]{1,128}$' -or
        [string]$repository.id -cnotmatch
            '^[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}$' -or
        [string]$alias -cnotmatch '^[a-zA-Z0-9._%+-]+(?:@[a-zA-Z0-9.-]+)?$') {
        throw 'private-provider-identity-unavailable'
    }
    $expectedProjectId = [string]$ProviderConfig['projectId']
    if (($expectedProjectId -and $expectedProjectId -cnotmatch
            '^[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}$') -or
        ($null -ne $account -and ($account -isnot [Collections.IDictionary] -or
            [string]$account.id -cnotmatch
                '^[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}$' -or
            [string]$account.descriptor -cnotmatch '^\S{1,512}$' -or
            [string]$account.uniqueName -cnotmatch '^[^@\s]+@[^@\s]+$'))) {
        throw 'private-provider-identity-unavailable'
    }
    if ($ApprovedSources -isnot [Collections.IDictionary]) {
        throw 'rule-source-not-approved'
    }
    Assert-CanarySource $ApprovedSources['owner'] $script:DocumentPath $script:OwnerCommit
    Assert-CanarySource $ApprovedSources['namedSection'] $script:DocumentPath ''
    foreach ($policy in $script:StaticPolicies) {
        $path = "/src/DevPilot.OwnerCapability/Policy/$($policy.file).v1.txt"
        Assert-CanarySource $ApprovedSources[$policy.name] $path ''
    }
    $templateRoot = Join-Path $RepositoryRoot 'samples'
    $intake = Get-Content -LiteralPath (Join-Path $templateRoot `
            'active-pr-intake.config.json') -Raw |
        ConvertFrom-Json -AsHashtable
    $config = Get-Content -LiteralPath (Join-Path $templateRoot `
            'rule-evaluation.config.json') -Raw |
        ConvertFrom-Json -AsHashtable
    $intake.organization = "https://dev.azure.com/$($repository.organization)"
    $intake.projectName = [string]$repository.project
    $intake.projectId = ''
    $intake.repositoryId = [string]$repository.id
    $intake.rules = @($config.rules | ForEach-Object {
            @{ id = [string]$_.ruleId; capability = [string]$_.capabilityId }
        })
    $intake.limits.maxHeadsPerRun = $CanaryPullRequestIds.Count
    $intake.limits.maxReads = 3000
    $intake.limits.maxSeconds = 240
    $config.organization = $intake.organization
    $config.projectId = $intake.projectId
    $config.repositoryId = $intake.repositoryId
    $config.limits.maxHeadsPerRun = $CanaryPullRequestIds.Count
    $config.limits.maxReads = 3000
    $config.limits.maxSeconds = 240
    if (-not $Run) {
        return @{ state = 'disabled'; owner = 'unknown/not-attempted'
            providerReads = 0; providerWrites = 0 }
    }
    if (-not $Provider) {
        $Provider = New-ActivePrAzureDevOpsProvider -Config $intake `
            -AzureCliPath $AzureCliPath -Bootstrap -VerifyReadPrincipal
    }
    $identity = & $Provider Identity @{}
    $metadata = & $Provider Metadata @{ repositoryName = $repository.name }
    if ($identity -isnot [Collections.IDictionary] -or
        [string]$identity.id -cnotmatch
            '^[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}$' -or
        [string]$identity.descriptor -cnotmatch '^\S{1,512}$' -or
        [string]$identity.uniqueName -cnotmatch '^[^@\s]+@[^@\s]+$' -or
        ($alias -ine [string]$identity.uniqueName -and
            $alias -ine ([string]$identity.uniqueName).Split('@')[0]) -or
        ($null -ne $account -and
            ([string]$identity.id -ine [string]$account.id -or
                [string]$identity.descriptor -cne [string]$account.descriptor -or
                [string]$identity.uniqueName -ine [string]$account.uniqueName)) -or
        $metadata -isnot [Collections.IDictionary] -or
        [string]$metadata.projectId -cnotmatch
            '^[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}$' -or
        ($expectedProjectId -and
            [string]$metadata.projectId -ine $expectedProjectId) -or
        [string]$metadata.projectName -cne [string]$repository.project -or
        [string]$metadata.repositoryId -ine [string]$repository.id -or
        [string]$metadata.repositoryName -cne [string]$repository.name) {
        throw 'private-provider-identity-mismatch'
    }
    $intake.projectId = [string]$metadata.projectId
    $intake.expectedAccount = [ordered]@{
        id = [string]$identity.id
        descriptor = [string]$identity.descriptor
        uniqueName = [string]$identity.uniqueName
    }
    $config.projectId = $intake.projectId
    if (-not $PSBoundParameters.ContainsKey('Provider')) {
        $Provider = New-ActivePrAzureDevOpsProvider -Config $intake `
            -AzureCliPath $AzureCliPath -VerifyReadPrincipal
    }
    $intake.enabled = $true
    $root = Resolve-AgentTrustedRoot -Path $StateRoot -Kind durable-state `
        -RepositoryRoot $RepositoryRoot -Create
    $intakeResult = Invoke-ActivePrIntake -Config $intake -Provider $Provider `
        -StateRoot $root -RepositoryRoot $RepositoryRoot `
        -CanaryPullRequestIds $CanaryPullRequestIds -Run
    if ($intakeResult.inventory.state -cne 'complete' -or
        $intakeResult.populationKnown -cne $true -or
        $intakeResult.gapCounts.enumerationUnknown -ne 0) {
        throw 'canary-inventory-unknown'
    }
    $pins = @($CanaryPullRequestIds | ForEach-Object {
            $id = $_
            $head = @($intakeResult.heads | Where-Object pullRequestId -EQ $id)
            if ($head.Count -ne 1 -or $head[0].targetRef -cne 'refs/heads/master' -or
                $head[0].status -cne 'pending' -or $null -eq $head[0].lineEvidence) {
                throw 'canary-head-or-evidence-unknown'
            }
            [ordered]@{
                pullRequestId = $id
                sourceCommit = $head[0].sourceCommit
                targetCommit = $head[0].targetCommit
                targetRef = $head[0].targetRef
                iterationId = $head[0].iterationId
                declarationDigest = $head[0].declarationDigest
                lineEvidenceDigest = $head[0].lineEvidenceDigest
            }
        })
    $document = Read-CanarySource $Provider $ApprovedSources.owner $script:DocumentPath
    $ownerSection = Get-CanarySection $document '## Claim ownership'
    if ((Get-CanaryTextHash $ownerSection) -cne $script:OwnerHash -or
        [Text.Encoding]::UTF8.GetByteCount($ownerSection) -gt 65536) {
        throw 'owner-rule-digest-mismatch'
    }
    $namedDocument = Read-CanarySource $Provider $ApprovedSources.namedSection `
        $script:DocumentPath
    $namedSection = Get-CanaryRawSection $namedDocument '## Named parameters for Assert'
    if ((Get-CanaryTextHash $namedSection) -cne $script:NamedSectionHash -or
        [Text.Encoding]::UTF8.GetByteCount($namedSection) -ne
            $script:NamedSectionLength) {
        throw 'named-rule-digest-mismatch'
    }
    $config.provenance = [ordered]@{
        ownerSection = [ordered]@{
            repositoryId = [string]$ApprovedSources.owner.repositoryId
            commit = $script:OwnerCommit
            path = $script:DocumentPath.Substring(1)
            section = '## Claim ownership'
            hash = 'v1:sha256:' + $script:OwnerHash
            length = [Text.Encoding]::UTF8.GetByteCount($ownerSection)
        }
        namedSection = [ordered]@{
            repositoryId = [string]$ApprovedSources.namedSection.repositoryId
            commit = [string]$ApprovedSources.namedSection.commit
            path = $script:DocumentPath.Substring(1)
            section = '## Named parameters for Assert'
            hash = 'v1:sha256:' + (Get-CanaryTextHash $namedSection)
            length = [Text.Encoding]::UTF8.GetByteCount($namedSection)
        }
    }
    foreach ($policy in $script:StaticPolicies) {
        $source = $ApprovedSources[$policy.name]
        $path = "/src/DevPilot.OwnerCapability/Policy/$($policy.file).v1.txt"
        $remoteText = Read-CanarySource $Provider $source $path
        $localPath = Join-Path $RepositoryRoot (
            "src\DevPilot.OwnerCapability\Policy\$($policy.file).v1.txt")
        $localText = [IO.File]::ReadAllText($localPath,
            [Text.UTF8Encoding]::new($false, $true))
        if ((Get-CanaryTextHash $remoteText) -cne (Get-CanaryTextHash $localText)) {
            throw 'static-rule-digest-mismatch'
        }
        $rule = $config.rules[$policy.index]
        $rule.enabled = $true
        $rule.binding = [ordered]@{
            ruleRepositoryId = [string]$source.repositoryId
            rulePath = $path.Substring(1)
            ruleCommit = [string]$source.commit
            ruleHash = 'v1:sha256:' + (Get-CanaryTextHash $localText)
            capabilityDigest = 'v1:sha256:' + (
                Get-CanaryTextHash "$($policy.file)-capability-v1")
        }
    }
    $config.canary = [ordered]@{
        schemaVersion = 1
        intakeGeneration = [string]$intakeResult.generation
        intakeConfigDigest = [string]$intakeResult.binding.configDigest
        heads = $pins
    }
    $config.enabled = $true
    $config.signature = ''
    $keyBytes = [Security.Cryptography.RandomNumberGenerator]::GetBytes(48)
    $key = [Convert]::ToBase64String($keyBytes)
    $unsigned = [ordered]@{}
    foreach ($entry in $config.Keys) {
        if ([string]$entry -cne 'signature') { $unsigned[[string]$entry] = $config[$entry] }
    }
    $hmac = [Security.Cryptography.HMACSHA256]::new(
        [Text.Encoding]::UTF8.GetBytes($key))
    try {
        $config.signature = 'v1:hmac-sha256:' +
            [Convert]::ToHexString($hmac.ComputeHash(
                    [Text.Encoding]::UTF8.GetBytes(
                        (ConvertTo-AgentCanonicalJson -InputObject $unsigned))
                )).ToLowerInvariant()
    }
    finally { $hmac.Dispose() }
    Write-CanaryPrivateFile (Join-Path $root 'signature.key') `
        ([Text.Encoding]::ASCII.GetBytes($key))
    [void](Assert-AgentTrustedFile -Path (Join-Path $root 'signature.key') `
            -AllowedRoot $root -Private)
    Write-CanaryPrivateFile (Join-Path $root 'canary-intake.json') `
        ([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $intake -Depth 32)))
    Write-CanaryPrivateFile (Join-Path $root 'canary-evaluation.json') `
        ([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $config -Depth 32)))
    $result = Invoke-BoundedRuleEvaluation -Config $config -IntakeConfig $intake `
        -Provider $Provider -StateRoot $root -RepositoryRoot $RepositoryRoot `
        -SignatureKey $key -CanaryPullRequestIds $CanaryPullRequestIds -Run
    $selectedResults = @($result.heads | Where-Object {
            $_.pullRequestId -in $CanaryPullRequestIds
        })
    return [ordered]@{
        state = if (@($selectedResults | ForEach-Object {
                    @($_.rules | Where-Object status -IN @('unknown', 'error'))
                }).Count -gt 0) { 'unknown' } else { 'read-only' }
        owner = 'unknown/not-attempted'
        inventory = [ordered]@{
            active = $intakeResult.inventory.active
            draft = $intakeResult.inventory.draft
            eligible = $intakeResult.inventory.eligible
            pagesFirst = $intakeResult.pages.first
            pagesSecond = $intakeResult.pages.second
        }
        intakeGeneration = $intakeResult.generation
        evaluationGeneration = $result.generation
        configDigest = $result.binding.configDigest
        ruleDigests = @($config.rules | Where-Object enabled | ForEach-Object {
                $_.binding.ruleHash
            })
        selected = $selectedResults.Count
        ruleCounts = @($config.rules | ForEach-Object {
                $rule = $_
                $entries = @($selectedResults | ForEach-Object {
                        @($_.rules | Where-Object capabilityId -CEQ $rule.capabilityId)
                    })
                [ordered]@{
                    capabilityId = $rule.capabilityId
                    evaluated = @($entries | Where-Object status -EQ 'evaluated').Count
                    unknown = if ($rule.capabilityId -ceq 'bpm-test-ownership@1') {
                        $selectedResults.Count
                    } else {
                        @($entries | Where-Object status -IN @('unknown', 'error')).Count
                    }
                    wouldCreate = @($entries | Where-Object status -EQ 'evaluated' |
                        ForEach-Object {
                            $observation = Get-Content -LiteralPath (
                                Join-Path $root "rule-evaluation-v1\observations\$($_.observationDigest).json"
                            ) -Raw | ConvertFrom-Json -AsHashtable
                            $observation.outcome.wouldCreate
                        } | Measure-Object -Sum).Sum
                }
            })
        providerWrites = 0
        writerEligible = $false
    }
}

Export-ModuleMember -Function Invoke-ActivePrCanaryQualification,
    Assert-CanaryCoverageSource, Invoke-PrivateCanaryBootstrap
