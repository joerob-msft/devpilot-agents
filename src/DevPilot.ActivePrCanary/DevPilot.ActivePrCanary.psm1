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

function Get-CanarySignature {
    param([Collections.IDictionary]$Config, [string]$Key)
    $unsigned = [ordered]@{}
    foreach ($entry in $Config.Keys) {
        if ([string]$entry -cne 'signature') { $unsigned[[string]$entry] = $Config[$entry] }
    }
    $hmac = [Security.Cryptography.HMACSHA256]::new(
        [Text.Encoding]::UTF8.GetBytes($Key))
    try {
        return 'v1:hmac-sha256:' +
            [Convert]::ToHexString($hmac.ComputeHash(
                    [Text.Encoding]::UTF8.GetBytes(
                        (ConvertTo-AgentCanonicalJson -InputObject $unsigned))
                )).ToLowerInvariant()
    }
    finally { $hmac.Dispose() }
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

function Get-CanaryIdentityPayload {
    param([byte[]]$Bytes, [AllowEmptyString()][string]$MediaType,
        [bool]$Encoded)
    if ($Encoded) { return @{ reason = 'encoded-response' } }
    if ($MediaType -and $MediaType -cne 'application/json' -and
        $MediaType -cnotmatch '^application/[A-Za-z0-9._-]+\+json$') {
        return @{ reason = 'non-json-media' }
    }
    if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xef -and
        $Bytes[1] -eq 0xbb -and $Bytes[2] -eq 0xbf) {
        return @{ reason = 'utf8-bom' }
    }
    try { $text = [Text.UTF8Encoding]::new($false, $true).GetString($Bytes) }
    catch [Text.DecoderFallbackException] {
        return @{ reason = 'invalid-utf8' }
    }
    catch { return @{ reason = 'unclassified' } }
    try { $result = $text | ConvertFrom-Json -AsHashtable -Depth 12 }
    catch {
        $document = $null
        try {
            $options = [Text.Json.JsonDocumentOptions]::new()
            $options.MaxDepth = 65536
            $document = [Text.Json.JsonDocument]::Parse($text, $options)
        }
        catch [Text.Json.JsonException] {
            return @{ reason = 'invalid-json' }
        }
        catch { return @{ reason = 'unclassified' } }
        finally { if ($document) { $document.Dispose() } }
        $shallow = $null
        try {
            $options.MaxDepth = 12
            $shallow = [Text.Json.JsonDocument]::Parse($text, $options)
        }
        catch [Text.Json.JsonException] {
            return @{ reason = 'json-depth-over-12' }
        }
        catch { return @{ reason = 'unclassified' } }
        finally { if ($shallow) { $shallow.Dispose() } }
        return @{ reason = 'unclassified' }
    }
    if ($result -isnot [Collections.IDictionary] -or
        $result['authenticatedUser'] -isnot [Collections.IDictionary]) {
        return @{ reason = 'identity-fields-missing' }
    }
    $user = $result['authenticatedUser']
    foreach ($field in @('id', 'subjectDescriptor', 'uniqueName')) {
        if (-not $user.Contains($field)) {
            return @{ reason = 'identity-fields-missing' }
        }
    }
    return @{ reason = 'valid'; identity = @{
            id = $user['id']; descriptor = $user['subjectDescriptor']
            uniqueName = $user['uniqueName'] } }
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
    $failureStatus = 0
    $phase = 'send'
    $decodeReason = ''
    try {
        $response = $Client.SendAsync($message,
            [Net.Http.HttpCompletionOption]::ResponseHeadersRead,
            $cancel.Token).GetAwaiter().GetResult()
        try {
            if (-not $response.IsSuccessStatusCode) {
                $failureStatus = [int]$response.StatusCode
                throw 'bootstrap-read-inaccessible'
            }
            $phase = 'read'
            if ($null -ne $response.Content.Headers.ContentLength -and
                    $response.Content.Headers.ContentLength -gt $limit) {
                throw 'bootstrap-read-inaccessible'
            }
            $mediaType = if ($response.Content.Headers.ContentType) {
                [string]$response.Content.Headers.ContentType.MediaType
            } else { '' }
            $encoded = $response.Content.Headers.ContentEncoding.Count -gt 0
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
        $phase = 'decode'
        if ($Operation -ceq 'Identity') {
            $classified = Get-CanaryIdentityPayload -Bytes $bytes `
                -MediaType $mediaType -Encoded $encoded
            $decodeReason = [string]$classified.reason
            if ($decodeReason -cne 'valid') {
                throw 'bootstrap-read-inaccessible'
            }
            return $classified.identity
        }
        $result = [Text.UTF8Encoding]::new($false, $true).GetString($bytes) |
            ConvertFrom-Json -AsHashtable -Depth 12
        return $result
    }
    catch {
        if ($failureStatus -gt 0) {
            throw ('bootstrap-read-inaccessible:{0}:http-{1}' -f
                $Operation, $failureStatus)
        }
        if ($Operation -ceq 'Identity' -and $phase -ceq 'decode' -and
            $decodeReason -cin @('encoded-response', 'non-json-media',
                'utf8-bom', 'invalid-utf8', 'invalid-json',
                'json-depth-over-12', 'identity-fields-missing',
                'unclassified')) {
            throw "bootstrap-read-inaccessible:Identity:$decodeReason"
        }
        throw ('bootstrap-read-inaccessible:{0}:{1}' -f $Operation, $phase)
    }
    finally {
        $cancel.Dispose()
        $message.Dispose()
    }
}

function Invoke-PrivateCanaryIdentityDiagnostic {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Organization,
        [Parameter(Mandatory)][string]$ExpectedAccountUniqueName,
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [string]$AzureCliPath = 'az',
        [scriptblock]$Read,
        [switch]$Run
    )
    if ($Organization -cnotmatch '^[A-Za-z0-9_-]{1,128}$' -or
        $ExpectedAccountUniqueName -cnotmatch '^[^@\s]+@[^@\s]+$' -or
        -not [IO.Path]::IsPathFullyQualified($RepositoryRoot)) {
        throw 'identity-diagnostic-input-invalid'
    }
    if (-not $Run) {
        return [ordered]@{ state = 'disabled'; reason = 'disabled'
            getAttempts = 0; providerWrites = 0; modelToolInvocations = 0 }
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
            $client.Timeout = [TimeSpan]::FromSeconds(30)
            $aadGet = ${function:Invoke-CanaryAadGet}
            $readClient = $client
            $readToken = $token
            $readOrg = $Organization
            $Read = {
                param($Operation, $Request)
                & $aadGet $readClient $readToken $readOrg `
                    $Operation $Request ([DateTime]::UtcNow.AddSeconds(30))
            }.GetNewClosure()
        }
        try {
            $identity = & $Read Identity @{}
        }
        catch {
            $message = [string]$_.Exception.Message
            $reason = if ($message -cmatch
                    '^bootstrap-read-inaccessible:Identity:(encoded-response|non-json-media|utf8-bom|invalid-utf8|invalid-json|json-depth-over-12|identity-fields-missing|unclassified)$') {
                $Matches[1]
            } elseif ($message -cmatch
                    '^bootstrap-read-inaccessible:Identity:http-[0-9]{3}$') {
                'http-failure'
            } elseif ($message -ceq 'bootstrap-read-inaccessible:Identity:send') {
                'send-failure'
            } elseif ($message -ceq 'bootstrap-read-inaccessible:Identity:read') {
                'read-failure'
            } else { 'unclassified' }
            return [ordered]@{ state = 'unknown'; reason = $reason
                getAttempts = 1; providerWrites = 0; modelToolInvocations = 0 }
        }
        $reason = 'valid'
        if ($identity -isnot [Collections.IDictionary] -or
            [string]$identity['id'] -cnotmatch
                '^[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}$' -or
            [string]$identity['descriptor'] -cnotmatch '^\S{1,512}$' -or
            [string]$identity['uniqueName'] -cnotmatch '^[^@\s]+@[^@\s]+$') {
            $reason = 'identity-fields-invalid'
        } elseif ([string]$identity['uniqueName'] -ine $ExpectedAccountUniqueName) {
            $reason = 'principal-mismatch'
        }
        return [ordered]@{
            state = if ($reason -ceq 'valid') { 'verified' } else { 'unknown' }
            reason = $reason; getAttempts = 1
            providerWrites = 0; modelToolInvocations = 0
        }
    }
    finally { if ($client) { $client.Dispose() } }
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

function Read-CanaryVerifiedDocument {
    param([scriptblock]$Read, [string]$RepositoryId, [string]$Revision)
    $request = @{ projectName = 'Engineering'; repositoryId = $RepositoryId
        path = $script:DocumentPath; commit = $Revision }
    $item = & $Read Item $request
    if ($item -isnot [Collections.IDictionary] -or
        [string]$item.path -cne $script:DocumentPath -or
        [string]$item.objectId -cnotmatch '^[a-fA-F0-9]{40}$' -or
        [string]$item.gitObjectType -cne 'blob' -or
        $item['isFolder'] -eq $true -or $item['isSymLink'] -eq $true) {
        throw 'bootstrap-blob-unverified'
    }
    $raw = & $Read RawItem $request
    if ($raw -isnot [Collections.IDictionary] -or
        $raw.bytes -isnot [byte[]] -or $raw.bytes.Length -gt 262144) {
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
        $readBudget = @{ count = 0 }
        $bounded = {
            param($Operation, $Request)
            if ($readBudget.count -ge 20) { throw 'bootstrap-read-budget' }
            $readBudget.count++
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
        $ownerSource = Read-CanaryVerifiedDocument $bounded $engId $script:OwnerCommit
        $ownerSection = Get-CanarySection $ownerSource.text '## Claim ownership'
        $namedSection = Get-CanaryRawSection $ownerSource.text `
            '## Named parameters for Assert'
        if ((Get-CanaryTextHash $ownerSection) -cne $script:OwnerHash -or
            (Get-CanaryTextHash $namedSection) -cne $script:NamedSectionHash -or
            [Text.Encoding]::UTF8.GetByteCount($namedSection) -ne
                $script:NamedSectionLength) {
            throw 'bootstrap-section-mismatch'
        }
        $coverageSource = Read-CanaryVerifiedDocument $bounded $engId $script:CoverageCommit
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
            canaryExecuted = $false; providerReads = $readBudget.count
            providerWrites = 0
            ruleCount = 4; candidateCount = 2
            documentHash = 'v1:sha256:' + $script:CoverageDocumentHash
            localCommit = $localCommit
        }
    }
    finally { if ($client) { $client.Dispose() } }
}

function New-VerifiedCanaryRuleRegistry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$ProviderConfig,
        [Parameter(Mandatory)][Collections.IDictionary]$ApprovedSources,
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [scriptblock]$Read,
        [switch]$Run
    )
    if (-not $Run) {
        return [ordered]@{ state = 'disabled'; providerReads = 0
            providerWrites = 0; evaluated = $false; writerEligible = $false }
    }
    if (-not $Read -or -not [IO.Path]::IsPathFullyQualified($RepositoryRoot) -or
        $ProviderConfig.provider -cne 'AzureDevOps' -or
        $ProviderConfig.repository -isnot [Collections.IDictionary] -or
        $ProviderConfig.expectedAccount -isnot [Collections.IDictionary] -or
        [string]$ProviderConfig.repository.organization -cnotmatch '^[A-Za-z0-9_-]{1,128}$' -or
        [string]$ProviderConfig.repository.project -cnotmatch '^[\w .-]{1,128}$' -or
        [string]$ProviderConfig.repository.name -cnotmatch '^[A-Za-z0-9._-]{1,128}$' -or
        [string]$ProviderConfig.repository.id -cnotmatch
            '^[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}$' -or
        [string]$ProviderConfig.projectId -cnotmatch
            '^[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}$' -or
        [string]$ProviderConfig.expectedAccount.id -cnotmatch
            '^[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}$' -or
        [string]$ProviderConfig.expectedAccount.descriptor -cnotmatch '^\S{1,512}$' -or
        [string]$ProviderConfig.expectedAccount.uniqueName -cnotmatch
            '^[^@\s]+@[^@\s]+$' -or
        [string]$ProviderConfig.operator.defaultAlias -ine
            [string]$ProviderConfig.expectedAccount.uniqueName -or
        $ApprovedSources.schemaVersion -ne 2 -or
        $ApprovedSources.kind -cne 'private-read-only-canary-sources' -or
        $ApprovedSources.sourceAuthority -cne
            'unmerged-reviewed-pr-is-candidate-only' -or
        $ApprovedSources.rules -isnot [Collections.IDictionary] -or
        $ApprovedSources.rules.Count -ne 4) {
        throw 'canary-receipt-invalid'
    }
    $rules = $ApprovedSources.rules
    $owner = $rules['bpm-test-ownership@1']
    $namedSection = $ApprovedSources['namedSection']
    $named = $rules['bpm-named-areequal-arguments@1']
    $class = $rules['bpm-test-class-coverage@2']
    $redundant = $rules['bpm-redundant-method-coverage@2']
    $engId = [string]$owner.repositoryId
    foreach ($source in @($owner, $namedSection, $class, $redundant)) {
        $expectedCommit = if ($source -eq $class -or $source -eq $redundant) {
            $script:CoverageCommit
        } else { $script:OwnerCommit }
        Assert-CanarySource $source $script:DocumentPath $expectedCommit
        if ([string]$source.projectName -cne 'Engineering' -or
            [string]$source.repositoryName -cne 'EngHub' -or
            [string]$source.repositoryId -cne $engId -or
            [string]$source.blobId -cnotmatch '^[a-f0-9]{40}$') {
            throw 'canary-receipt-invalid'
        }
    }
    if ($owner.section -cne '## Claim ownership' -or
        $owner.sectionHash -cne ('v1:sha256:' + $script:OwnerHash) -or
        [string]$owner.sectionLength -cnotmatch '^[1-9][0-9]{0,4}$' -or
        [int]$owner.sectionLength -gt 65536 -or
        $namedSection.section -cne '## Named parameters for Assert' -or
        $namedSection.sectionHash -cne
            ('v1:sha256:' + $script:NamedSectionHash) -or
        $namedSection.sectionLength -ne $script:NamedSectionLength -or
        $namedSection.blobId -cne $owner.blobId -or
        $owner.declarationDigest -cne ('v1:sha256:' + (Get-CanaryTextHash (
                    ConvertTo-AgentCanonicalJson -InputObject ([ordered]@{
                            ruleId = 'bpm-test-ownership@1'
                            repositoryId = $engId
                            commit = $script:OwnerCommit
                            path = $script:DocumentPath
                            sectionHash = $owner.sectionHash
                            sectionLength = $owner.sectionLength
                        }))))) {
        throw 'canary-receipt-invalid'
    }
    $readBudget = @{ count = 0 }
    $bounded = {
        param($Operation, $Request)
        if ($readBudget.count -ge 20 -or $Operation -cnotin @('Identity', 'Project',
                'Repository', 'PullRequest', 'Iterations', 'Ref', 'Commit',
                'Item', 'RawItem')) {
            throw 'registry-read-budget'
        }
        $readBudget.count++
        $answer = & $Read $Operation $Request
        if ($answer -isnot [Collections.IDictionary]) {
            throw 'registry-read-inaccessible'
        }
        return $answer
    }.GetNewClosure()
    $identity = & $bounded Identity @{}
    $projectName = [string]$ProviderConfig.repository.project
    $project = & $bounded Project @{ projectName = $projectName }
    $repo = & $bounded Repository @{
        projectName = $projectName
        repositoryName = [string]$ProviderConfig.repository.name
    }
    $engineering = & $bounded Project @{ projectName = 'Engineering' }
    $enghub = & $bounded Repository @{
        projectName = 'Engineering'; repositoryName = 'EngHub'
    }
    if ([string]$identity.id -ine [string]$ProviderConfig.expectedAccount.id -or
        [string]$identity.descriptor -cne
            [string]$ProviderConfig.expectedAccount.descriptor -or
        [string]$identity.uniqueName -ine
            [string]$ProviderConfig.expectedAccount.uniqueName -or
        [string]$project.id -ine [string]$ProviderConfig.projectId -or
        [string]$project.name -cne $projectName -or
        [string]$repo.id -ine [string]$ProviderConfig.repository.id -or
        [string]$repo.name -cne [string]$ProviderConfig.repository.name -or
        [string]$repo.project.id -ine [string]$project.id -or
        [string]$repo.project.name -cne $projectName -or
        [string]$engineering.id -cnotmatch
            '^[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}$' -or
        [string]$engineering.name -cne 'Engineering' -or
        [string]$enghub.id -ine $engId -or
        [string]$enghub.name -cne 'EngHub' -or
        [string]$enghub.project.id -ine [string]$engineering.id -or
        [string]$enghub.project.name -cne 'Engineering') {
        throw 'canary-identity-drift'
    }
    Assert-CanaryBootstrapHead $bounded $engId ([string]$engineering.id)
    $commit = & $bounded Commit @{
        projectName = 'Engineering'; repositoryId = $engId
        commit = $script:CoverageCommit
    }
    if ([string]$commit.commitId -ine $script:CoverageCommit) {
        throw 'coverage-commit-unverified'
    }
    $ownerSource = Read-CanaryVerifiedDocument $bounded $engId $script:OwnerCommit
    $ownerBytes = Get-CanarySection $ownerSource.text '## Claim ownership'
    $namedBytes = Get-CanaryRawSection $ownerSource.text `
        '## Named parameters for Assert'
    if ($ownerSource.blobId -cne $owner.blobId -or
        (Get-CanaryTextHash $ownerBytes) -cne $script:OwnerHash -or
        [Text.Encoding]::UTF8.GetByteCount($ownerBytes) -ne
            [int]$owner.sectionLength -or
        (Get-CanaryTextHash $namedBytes) -cne $script:NamedSectionHash -or
        [Text.Encoding]::UTF8.GetByteCount($namedBytes) -ne
            $script:NamedSectionLength) {
        throw 'canary-section-drift'
    }
    $coverageSource = Read-CanaryVerifiedDocument $bounded $engId $script:CoverageCommit
    $coverageBytes = [Text.Encoding]::UTF8.GetBytes($coverageSource.text)
    if ($coverageBytes.Length -ne $script:CoverageDocumentLength -or
        (Get-CanaryHash $coverageBytes) -cne $script:CoverageDocumentHash) {
        throw 'coverage-source-bytes-mismatch'
    }
    $declarations = @(Get-CanaryCoverageDeclarations $coverageSource.text $engId)
    $candidateSources = @($class, $redundant)
    for ($i = 0; $i -lt 2; $i++) {
        $source = $candidateSources[$i]
        $expected = $declarations[$i]
        if ($source.ruleId -cne $expected.ruleId -or
            $source.provenance -cne 'unmerged-reviewed-pr' -or
            $source.reviewedPullRequestId -ne 17307009 -or
            $source.reviewedHead -cne $script:CoverageCommit -or
            $source.headVerified -cne $true -or
            $source.documentHash -cne
                ('v1:sha256:' + $script:CoverageDocumentHash) -or
            $source.blobId -cne $coverageSource.blobId -or
            $source.section -cne $expected.section -or
            $source.sectionHash -cne $expected.sectionHash -or
            $source.policyLine -ne $expected.policyLine -or
            $source.policyLineHash -cne $expected.policyLineHash -or
            $source.declarationDigest -cne $expected.declarationDigest) {
            throw 'coverage-receipt-drift'
        }
    }
    Assert-CanaryBootstrapHead $bounded $engId ([string]$engineering.id)
    $finalIdentity = & $bounded Identity @{}
    if ([string]$finalIdentity.id -ine [string]$identity.id -or
        [string]$finalIdentity.descriptor -cne [string]$identity.descriptor -or
        [string]$finalIdentity.uniqueName -ine [string]$identity.uniqueName) {
        throw 'canary-identity-drift'
    }
    $path = 'src/DevPilot.OwnerCapability/Policy/named-areequal-arguments.v1.txt'
    if ($named -isnot [Collections.IDictionary] -or
        $named.approved -cne $true -or
        $named.provenance -cne 'repository-local-commit' -or
        $named.path -cne $path -or
        [string]$named.commit -cnotmatch '^[a-f0-9]{40}$' -or
        $named.ruleRepository -cne (Get-CanaryGitRepository $RepositoryRoot) -or
        $named.namedSectionHash -cne $namedSection.sectionHash -or
        $named.capabilityDigest -cne ('v1:sha256:' + (
                Get-CanaryTextHash 'named-areequal-arguments-capability-v1')) -or
        $named.policyHash -cnotmatch '^v1:sha256:[a-f0-9]{64}$') {
        throw 'named-rule-receipt-invalid'
    }
    $localPath = Join-Path $RepositoryRoot (
        $path -replace '/', [IO.Path]::DirectorySeparatorChar)
    $local = [IO.File]::ReadAllBytes($localPath)
    if ($local.Length -gt 65536 -or
        $named.policyHash -cne ('v1:sha256:' + (Get-CanaryHash $local)) -or
        (Get-CanaryGitValue $RepositoryRoot @(
                'rev-parse', "$($named.commit):$path")) -cne
        (Get-CanaryGitValue $RepositoryRoot @('hash-object', '--', $path)) -or
        $named.declarationDigest -cne ('v1:sha256:' + (Get-CanaryTextHash (
                    ConvertTo-AgentCanonicalJson -InputObject ([ordered]@{
                            ruleId = 'bpm-named-areequal-arguments@1'
                            ruleRepository = $named.ruleRepository
                            commit = $named.commit; path = $path
                            policyHash = $named.policyHash
                            namedSectionHash = $named.namedSectionHash
                            capabilityDigest = $named.capabilityDigest
                        }))))) {
        throw 'named-rule-receipt-invalid'
    }
    $registry = [ordered]@{}
    foreach ($ruleId in @('bpm-test-ownership@1',
            'bpm-test-class-coverage@2',
            'bpm-redundant-method-coverage@2',
            'bpm-named-areequal-arguments@1')) {
        $source = $rules[$ruleId]
        $registry[$ruleId] = [ordered]@{
            id = $ruleId
            enabled = $false
            evaluated = $false
            writerEligible = $false
            sourceAuthority = if ($ruleId -in @(
                    'bpm-test-class-coverage@2',
                    'bpm-redundant-method-coverage@2')) {
                'verified-unmerged-candidate-only'
            } elseif ($ruleId -eq 'bpm-named-areequal-arguments@1') {
                'repository-local-commit'
            } else { 'pinned-owner-section' }
            declarationDigest = [string]$source.declarationDigest
            sourceCommit = [string]$source.commit
            sourceHash = if ($ruleId -eq 'bpm-named-areequal-arguments@1') {
                [string]$source.policyHash
            } else { [string]$source.sectionHash }
        }
    }
    return [ordered]@{
        schemaVersion = 1
        kind = 'verified-read-only-canary-registry'
        state = 'verified-not-evaluated'
        sourceAuthority = 'unmerged-reviewed-pr-is-candidate-only'
        receiptDigest = 'v1:sha256:' + (Get-CanaryTextHash (
                ConvertTo-AgentCanonicalJson -InputObject ([ordered]@{
                        schemaVersion = $ApprovedSources.schemaVersion
                        kind = $ApprovedSources.kind
                        sourceAuthority = $ApprovedSources.sourceAuthority
                        namedSection = $namedSection
                        rules = $rules
                    })))
        verifiedUtc = [DateTime]::UtcNow.ToString('o')
        providerReads = $readBudget.count
        providerWrites = 0
        evaluated = $false
        writerEligible = $false
        owner = 'not-attempted;no-model-or-tools'
        rules = $registry
    }
}

function Invoke-PrivateCanaryRuleRegistry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$ProviderConfig,
        [Parameter(Mandatory)][Collections.IDictionary]$ApprovedSources,
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [string]$AzureCliPath = 'az',
        [switch]$Run
    )
    if (-not $Run) {
        return New-VerifiedCanaryRuleRegistry -ProviderConfig $ProviderConfig `
            -ApprovedSources $ApprovedSources -RepositoryRoot $RepositoryRoot
    }
    $organization = [string]$ProviderConfig.repository.organization
    if ($organization -cnotmatch '^[A-Za-z0-9_-]{1,128}$') {
        throw 'canary-receipt-invalid'
    }
    $template = Get-Content -LiteralPath (Join-Path $RepositoryRoot `
            'samples\active-pr-intake.config.json') -Raw |
        ConvertFrom-Json -AsHashtable
    $token = Get-CanaryAadToken $AzureCliPath `
        ([string]$template.identityResource)
    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $client = [Net.Http.HttpClient]::new($handler)
    try {
        $client.Timeout = [TimeSpan]::FromSeconds(120)
        $deadline = [DateTime]::UtcNow.AddSeconds(120)
        $aadGet = ${function:Invoke-CanaryAadGet}
        $read = {
            param($Operation, $Request)
            & $aadGet $client $token $organization $Operation $Request $deadline
        }.GetNewClosure()
        return New-VerifiedCanaryRuleRegistry -ProviderConfig $ProviderConfig `
            -ApprovedSources $ApprovedSources -RepositoryRoot $RepositoryRoot `
            -Read $read -Run
    }
    finally { $client.Dispose() }
}

function Invoke-PrivateCanarySignedIntake {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$ProviderConfig,
        [Parameter(Mandatory)][Collections.IDictionary]$ApprovedSources,
        [Parameter(Mandatory)][string]$StateRoot,
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][int[]]$CanaryPullRequestIds,
        [string]$AzureCliPath = 'az',
        [scriptblock]$Read,
        [scriptblock]$Provider,
        [switch]$Run
    )
    if ($CanaryPullRequestIds.Count -lt 1 -or $CanaryPullRequestIds.Count -gt 2 -or
        @($CanaryPullRequestIds | Where-Object { $_ -lt 1 }).Count -gt 0 -or
        @($CanaryPullRequestIds | Select-Object -Unique).Count -ne
            $CanaryPullRequestIds.Count) { throw 'invalid-canary-selection' }
    if (-not [IO.Path]::IsPathFullyQualified($StateRoot) -or
        -not [IO.Path]::IsPathFullyQualified($RepositoryRoot) -or
        (Test-AgentPathWithin $StateRoot $RepositoryRoot) -or
        (Test-AgentPathWithin $RepositoryRoot $StateRoot)) {
        throw 'state-root-must-be-external'
    }
    if (Test-Path -LiteralPath $StateRoot) { throw 'canary-state-root-must-be-new' }
    if (-not $Run) {
        return [ordered]@{ state = 'disabled'; signed = $false
            evaluated = $false; providerReads = 0; providerWrites = 0
            modelToolInvocations = 0; writerEligible = $false }
    }
    $sourceSnapshot = ConvertTo-Json -InputObject $ApprovedSources -Depth 32 -Compress
    $providerSnapshot = ConvertTo-Json -InputObject $ProviderConfig -Depth 32 -Compress
    $registryArgs = @{ ProviderConfig = $ProviderConfig
        ApprovedSources = $ApprovedSources; RepositoryRoot = $RepositoryRoot; Run = $true }
    if ($Read) {
        $registryArgs.Read = $Read
        $registry = New-VerifiedCanaryRuleRegistry @registryArgs
    } else {
        $registry = Invoke-PrivateCanaryRuleRegistry @registryArgs -AzureCliPath $AzureCliPath
    }
    if ($registry.state -cne 'verified-not-evaluated' -or
        $registry.rules.Count -ne 4 -or $registry.providerWrites -ne 0) {
        throw 'canary-registry-incomplete'
    }
    $templateRoot = Join-Path $RepositoryRoot 'samples'
    $intake = Get-Content -LiteralPath (Join-Path $templateRoot `
            'active-pr-intake.config.json') -Raw | ConvertFrom-Json -AsHashtable
    $intake.organization = "https://dev.azure.com/$($ProviderConfig.repository.organization)"
    $intake.projectName = [string]$ProviderConfig.repository.project
    $intake.projectId = [string]$ProviderConfig.projectId
    $intake.repositoryId = [string]$ProviderConfig.repository.id
    $intake.expectedAccount = $ProviderConfig.expectedAccount
    $intake.enabled = $true
    $intake.pagination = [ordered]@{ mode = 'created-time-keyset' }
    $intake.projectEvidence.enabled = $true
    $intake.rules = @($registry.rules.Keys | ForEach-Object {
            [ordered]@{ id = [string]$_; capability = [string]$_ }
        })
    $intake.limits.maxHeadsPerRun = $CanaryPullRequestIds.Count
    if (-not $Provider) {
        $Provider = New-ActivePrAzureDevOpsProvider -Config $intake `
            -AzureCliPath $AzureCliPath -VerifyReadPrincipal
    }
    $created = $false
    $root = Resolve-AgentTrustedRoot -Path $StateRoot -Kind durable-state `
        -RepositoryRoot $RepositoryRoot -Create -CreatedByCaller ([ref]$created)
    if (-not $created) { throw 'canary-state-root-must-be-new' }
    $cohort = Invoke-ActivePrIntake -Config $intake -Provider $Provider `
        -StateRoot $root -RepositoryRoot $RepositoryRoot `
        -CanaryPullRequestIds $CanaryPullRequestIds -Run
    if ($cohort.inventory.state -cne 'complete' -or
        $cohort.populationKnown -cne $true -or
        $cohort.gapCounts.enumerationUnknown -ne 0 -or
        $cohort.gapCounts.duplicateEntries -ne 0 -or
        $cohort.inventory.nonDraft -ne $cohort.heads.Count -or
        $cohort.inventory.active -ne
            ($cohort.inventory.draft + $cohort.inventory.nonDraft) -or
        $cohort.inventory.eligible -ne
            ($cohort.inventory.nonDraft - $cohort.inventory.excludedOtherTargets)) {
        throw 'canary-inventory-unknown'
    }
    $pins = @($CanaryPullRequestIds | ForEach-Object {
            $id = $_
            $heads = @($cohort.heads | Where-Object pullRequestId -EQ $id)
            if ($heads.Count -ne 1 -or
                $heads[0].status -cne 'pending' -or
                $heads[0].targetRef -cne 'refs/heads/master' -or
                $null -eq $heads[0].lineEvidence -or
                [string]$heads[0].lineEvidenceDigest -cnotmatch '^[a-f0-9]{64}$' -or
                $null -eq $heads[0].projectEvidence -or
                $heads[0].projectEvidence.complete -cne $true -or
                [string]$heads[0].projectEvidenceDigest -cnotmatch '^[a-f0-9]{64}$') {
                throw 'canary-head-or-evidence-unknown'
            }
            [ordered]@{
                pullRequestId = $id
                sourceCommit = $heads[0].sourceCommit
                targetCommit = $heads[0].targetCommit
                targetRef = $heads[0].targetRef
                iterationId = $heads[0].iterationId
                declarationDigest = $heads[0].declarationDigest
                lineEvidenceDigest = $heads[0].lineEvidenceDigest
                projectEvidenceDigest = $heads[0].projectEvidenceDigest
            }
        })
    if ($Read) {
        $finalRegistry = New-VerifiedCanaryRuleRegistry @registryArgs
    } else {
        $finalRegistry = Invoke-PrivateCanaryRuleRegistry @registryArgs `
            -AzureCliPath $AzureCliPath
    }
    if ($finalRegistry.receiptDigest -cne $registry.receiptDigest -or
        $finalRegistry.state -cne 'verified-not-evaluated' -or
        (ConvertTo-Json -InputObject $ApprovedSources -Depth 32 -Compress) -cne
            $sourceSnapshot -or
        (ConvertTo-Json -InputObject $ProviderConfig -Depth 32 -Compress) -cne
            $providerSnapshot) {
        throw 'canary-source-drift'
    }
    $config = [ordered]@{
        schemaVersion = 1
        kind = 'private-canary-signed-intake'
        enabled = $false
        readOnly = $true
        dryRun = $true
        writerEligible = $false
        modelEnabled = $false
        organization = $intake.organization
        projectId = $intake.projectId
        repositoryId = $intake.repositoryId
        expectedAccount = $intake.expectedAccount
        sourceAuthority = 'unmerged-reviewed-pr-is-candidate-only'
        receiptDigest = $registry.receiptDigest
        intakeGeneration = $cohort.generation
        intakeConfigDigest = $cohort.binding.configDigest
        heads = $pins
        rules = @($registry.rules.Keys | ForEach-Object {
                $rule = $registry.rules[$_]
                [ordered]@{
                    capabilityId = $rule.id
                    enabled = $false
                    evaluated = $false
                    writerEligible = $false
                    sourceAuthority = $rule.sourceAuthority
                    sourceCommit = $rule.sourceCommit
                    sourceHash = $rule.sourceHash
                    declarationDigest = $rule.declarationDigest
                }
            })
        limits = [ordered]@{
            maxHeadsPerRun = $CanaryPullRequestIds.Count
            maxReads = 3000
            maxSeconds = 240
            maxFindingsPerHead = 8
        }
        signature = ''
    }
    $key = [Convert]::ToBase64String(
        [Security.Cryptography.RandomNumberGenerator]::GetBytes(48))
    $config.signature = Get-CanarySignature $config $key
    foreach ($entry in @(
            @{ name = 'provider-config.json'; value = $ProviderConfig },
            @{ name = 'approved-sources.json'; value = $ApprovedSources },
            @{ name = 'canary-intake.json'; value = $intake },
            @{ name = 'canary-dispatcher.json'; value = $config })) {
        $file = Join-Path $root $entry.name
        Write-CanaryPrivateFile $file ([Text.Encoding]::UTF8.GetBytes(
                (ConvertTo-Json -InputObject $entry.value -Depth 32)))
        [void](Assert-AgentTrustedFile -Path $file -AllowedRoot $root -Private)
    }
    $keyFile = Join-Path $root 'signature.key'
    Write-CanaryPrivateFile $keyFile ([Text.Encoding]::ASCII.GetBytes($key))
    [void](Assert-AgentTrustedFile -Path $keyFile -AllowedRoot $root -Private)
    return [ordered]@{
        state = 'signed-intake-not-evaluated'
        signed = $true
        evaluated = $false
        writerEligible = $false
        providerReads = $registry.providerReads + $cohort.readCount +
            $finalRegistry.providerReads
        providerWrites = 0
        modelToolInvocations = 0
        inventory = [ordered]@{
            active = $cohort.inventory.active
            nonDraft = $cohort.inventory.nonDraft
            draft = $cohort.inventory.draft
            eligible = $cohort.inventory.eligible
            pagesFirst = $cohort.pages.first
            pagesSecond = $cohort.pages.second
        }
        intakeGeneration = $cohort.generation
        selected = $pins.Count
        pending = $cohort.counts.deferred + $pins.Count
        skipped = $cohort.counts.skipped
        unknown = $cohort.counts.error
        rules = @($config.rules | ForEach-Object {
                [ordered]@{ capabilityId = $_.capabilityId
                    evaluated = 0; humanCovered = 0; wouldCreate = 0
                    unknown = $pins.Count }
            })
    }
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
    $config.signature = Get-CanarySignature $config $key
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
    Assert-CanaryCoverageSource, Invoke-PrivateCanaryBootstrap,
    New-VerifiedCanaryRuleRegistry, Invoke-PrivateCanaryRuleRegistry,
    Invoke-PrivateCanarySignedIntake, Invoke-PrivateCanaryIdentityDiagnostic
